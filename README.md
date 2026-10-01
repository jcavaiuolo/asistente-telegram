# Asistente personal por Telegram (Claude Code + Channels)

Claude Code corre en una VM del server, conectado a un bot de Telegram. Registra gastos y transferencias, lleva las comidas, maneja el menú y te sugiere la cena todos los días a las 18:00. Los datos quedan en SQLite con auditoría de cambios. Funciona con tu plan Pro, sin API key.

```
Telegram ──► bot ──► plugin telegram (Bun) ──► sesión claude en tmux (systemd)
                                                    │
                                                    └─► bin/db ──► data/asistente.db
timer 18:00 ──► bin/cena ──► claude -p ──► API de Telegram (mensaje directo)
timer 04:00 ──► backup de la base + reinicio de la sesión
```

## Contenido

| Archivo | Para qué |
| --- | --- |
| `CLAUDE.md` | Las reglas del asistente: cómo registrar, corregir, sugerir. Editalo para cambiar comportamiento. |
| `schema.sql` | Tablas `movimientos`, `auditoria`, `platos`, `comidas`, `sugerencias` y vistas. |
| `.claude/settings.json` | Permisos: solo puede usar `bin/db`, guardar comprobantes y responder por Telegram. Web, curl, rm y sqlite directo bloqueados. |
| `bin/db` | Acceso a la base en modo `-safe` (sin `.shell`, sin ATTACH). |
| `bin/guardar-comprobante` | Copia fotos del inbox de Telegram a `comprobantes/AAAA/MM/`. |
| `bin/cena` | Sugerencia diaria, la manda directo por la API de Telegram. |
| `bin/backup` | Backup en caliente de la base, retiene 60 días. |
| `systemd/` | Servicio principal y timers (reinicio 04:00, cena 18:00). |
| `setup.sh` | Instalación automática en Debian. |

## Paso 1: la VM

En Proxmox: Debian 12 o 13, 2 vCPU, 2 GB de RAM, 16 GB de disco. No necesita puertos abiertos: el bot sale hacia Telegram, no recibe conexiones.

Si usás la imagen cloud de Debian (*genericcloud*), viene mínima: instalá `git` y `qemu-guest-agent` antes.

Cloná el repo y corré el setup:

```bash
ssh usuario@ip-vm
sudo apt install -y git qemu-guest-agent
git clone https://github.com/jcavaiuolo/asistente-telegram.git asistente
cd asistente
sudo bash setup.sh
```

Crea el usuario `asistente`, instala Claude Code, Bun, tmux, sqlite3 y jq, inicializa la base y deja los servicios habilitados.

## Paso 2: el bot

En Telegram, hablale a **@BotFather**, mandá `/newbot`, elegí nombre y usuario (terminado en `bot`). Guardá el token.

## Paso 3: primera vez, a mano

```bash
sudo -iu asistente
cd ~/asistente
claude
```

> **Importante: abrilo dentro de `~/asistente`.** La confianza en la carpeta se acepta por directorio. Si lo abrís en el home, el servicio queda después colgado en el diálogo de confianza de `~/asistente` sin dar ningún error, y el plugin de Telegram no arranca.

1. **Login:** elegí cuenta de Claude (suscripción). Te muestra una URL: abrila en tu PC o celular, autorizá y pegá el código en la terminal.
2. **Confianza en la carpeta:** aceptá. Te lista los permisos de `.claude/settings.json`, revisalos.
3. Instalá el plugin y cargá el token:
   ```
   /plugin marketplace add anthropics/claude-plugins-official
   /plugin install telegram@claude-plugins-official
   /telegram:configure 123456789:AAH...
   /exit
   ```
   (El primer comando solo hace falta si el install dice que no encuentra el marketplace. Cuando pregunte el scope, elegí *user*.)

## Paso 4: emparejar tu cuenta

Todavía como `asistente`, en `~/asistente`:

```bash
claude --channels plugin:telegram@claude-plugins-official
```

Mandale cualquier mensaje al bot. Te responde con un código. En la terminal:

```
/telegram:access pair <codigo>
/telegram:access policy allowlist
/exit
```

Con `allowlist` el bot ignora a cualquiera que no seas vos.

Si el bot no te responde con el código, revisá que exista un proceso `bun` colgando de `claude` (`ps -u asistente -o pid,args --forest`): es el servidor del plugin. Si no está, mirá los logs en `~/.cache/claude-cli-nodejs/<carpeta>/mcp-logs-plugin-telegram-telegram/`. El nombre de `<carpeta>` es el directorio donde corre claude con las `/` cambiadas por `-`: tiene que ser `-home-asistente-asistente`.

## Paso 5: dejarlo corriendo

```bash
exit                                  # volver a tu usuario
sudo systemctl start asistente
sudo systemctl status asistente
sudo systemctl start asistente-reinicio.timer asistente-cena.timer
systemctl list-timers 'asistente*'
```

El setup solo *habilita* los timers: sin el `start` no corren hasta el próximo reinicio de la VM.

`active` en `systemctl status` no garantiza que funcione: la sesión vive en tmux y systemd no ve qué muestra. Para revisar la pantalla sin entrar:

```bash
sudo -iu asistente tmux capture-pane -p -t asistente
```

Para mirar la sesión en vivo: `sudo -iu asistente tmux attach -t asistente`. Salís sin cortarla con `Ctrl+b`, soltás, y `d`. Un `/exit` o `Ctrl+c` adentro mata la sesión (systemd la vuelve a levantar a los 15 segundos).

Mientras estés adentro:
- Si abajo del prompt dice **auto mode on**, apretá `Shift+Tab` hasta que desaparezca. En auto mode Claude puede hacer cosas fuera de la lista de permisos sin pedirte aprobación por Telegram.
- Si el prompt muestra una sugerencia en gris, no apretes Enter ni Tab: se la mandás a Claude como si la hubieras escrito vos.

Probá la cena sin esperar a las 18: `sudo systemctl start asistente-cena.service`

## Paso 6: cargar el menú

Por Telegram, algo como:

> Agregá al menú: milanesas con puré, tarta de verdura, pollo al horno con papas, fideos con tuco, bife con ensalada, pizza casera, guiso de lentejas, salmón con verduras

Y después usalo normal:

- `pagué 12500 en el chino con débito`
- una captura del comprobante de Mercado Pago
- `me transfirió 50 lucas Juan por el asado`
- `cambiá el último a crédito` / `anulá el 42`
- `¿cuánto gasté este mes en súper?`
- `almorcé una ensalada césar`
- `sacá el guiso del menú`
- `¿qué ceno hoy?`

## Operación

- **Permisos fuera de lo permitido:** si Claude necesita algo que no está en la lista, el pedido te llega a Telegram con botones para aprobar o rechazar. Si te pide permiso para responder (`reply`), el nombre real de la herramienta difiere del de `settings.json`: mirá el nombre en el pedido y reemplazá la regla `mcp__plugin_telegram_telegram__*`.
- **Ver datos a mano:** `sudo -iu asistente /home/asistente/asistente/bin/db "SELECT * FROM v_gastos_mes LIMIT 20;"` (con ruta absoluta: un `~` lo expande tu shell a tu propio home antes del `sudo`)
- **Exportar a CSV:** `sudo -iu asistente sqlite3 -csv -header /home/asistente/asistente/data/asistente.db "SELECT * FROM v_movimientos" > movimientos.csv`
- **Cambiar la hora de la cena:** editá `OnCalendar` en `/etc/systemd/system/asistente-cena.timer` y corré `sudo systemctl daemon-reload`.
- **Logs:** `journalctl -u asistente -u asistente-cena -u asistente-reinicio`
- **Backups:** `~/asistente/backups/` todas las noches. Sumale el backup de la VM en Proxmox.
- **Cambiar reglas:** editá `CLAUDE.md` y reiniciá el servicio. Lo que le pidas por chat ("no repitas platos en 10 días") vive solo en la conversación y se pierde en el reinicio de las 04:00.
- **Si el token de login vence:** entrá con `sudo -iu asistente`, corré `claude` y `/login`, y reiniciá el servicio.

## A tener en cuenta

- Channels está en *research preview*: el flag `--channels` o el plugin pueden cambiar. Si se rompe tras una actualización, mirá la documentación de Channels de Claude Code.
- Los mensajes con el bot no están cifrados de punta a punta, y el contenido pasa por Anthropic. No mandes CBU, números de tarjeta ni claves.
- El consumo sale de tu plan Pro. Mensajes cortos gastan poco, pero si un día llegás al límite, el bot deja de responder hasta que se renueve.
- Los movimientos no se pueden borrar (lo impide un trigger): se anulan, y cada alta, cambio o anulación queda en `auditoria` con el antes y el después.
