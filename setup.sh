#!/usr/bin/env bash
# Instalación del asistente en una VM Debian 12/13 recién creada.
# Correr como root desde la carpeta descomprimida:  sudo bash setup.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Correr como root"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
U=asistente
DIR=/home/$U/asistente

echo "==> Paquetes y zona horaria"
apt-get update -qq
apt-get install -y -qq tmux sqlite3 jq curl unzip git ca-certificates
timedatectl set-timezone America/Argentina/Buenos_Aires

echo "==> Usuario $U"
id "$U" &>/dev/null || useradd -m -s /bin/bash "$U"

echo "==> Archivos del proyecto en $DIR"
mkdir -p "$DIR"/{data,comprobantes,backups}
cp -r "$SRC"/bin "$SRC"/web "$SRC"/.claude "$SRC"/CLAUDE.md "$SRC"/schema.sql "$DIR"/
chmod +x "$DIR"/bin/*
chown -R "$U:$U" /home/$U
chmod 700 "$DIR"/data "$DIR"/comprobantes "$DIR"/backups

echo "==> Claude Code y Bun (como $U)"
runuser -l "$U" -c 'command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash'
runuser -l "$U" -c 'command -v bun >/dev/null || curl -fsSL https://bun.sh/install | bash'
# En ~/.profile (no ~/.bashrc): el .bashrc de Debian corta en shells no interactivas, y así claude/bun
# también aparecen en `bash -lc` y `sudo -iu asistente comando`.
grep -q '.bun/bin' /home/$U/.profile 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> /home/$U/.profile

echo "==> Base de datos"
runuser -u "$U" -- bash -c "cd $DIR && bin/db < schema.sql"

echo "==> Servicios systemd (se habilitan, no se arrancan todavía)"
cp "$SRC"/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable asistente.service asistente-reinicio.timer asistente-cena.timer
# El tablero web no depende del login de Claude: se arranca ya.
systemctl enable --now asistente-web.service

IP="$(hostname -I | awk '{print $1}')"
cat <<MSG

Tablero web: http://$IP:8080

Listo la parte automática. Ahora los pasos manuales (ver README.md, "Paso 3"):
  sudo -iu $U
  cd ~/asistente && claude
MSG
