// Tablero web del asistente: gastos por día (solo lectura) y edición de menú y comidas.
// Pensado para la red interna, sin login. Corre como el usuario asistente:
//   bun web/server.ts          (variables opcionales: PORT, HOST, DB_PATH, ASISTENTE_DIR)
import { Database } from "bun:sqlite";
import { realpathSync } from "node:fs";
import { extname, join, resolve, sep } from "node:path";

const BASE = process.env.ASISTENTE_DIR ?? resolve(import.meta.dir, "..");
const DB_PATH = process.env.DB_PATH ?? join(BASE, "data", "asistente.db");
const PORT = Number(process.env.PORT ?? 8080);
const HOST = process.env.HOST ?? "0.0.0.0";
const COMPROBANTES = join(BASE, "comprobantes");
const INDEX = join(import.meta.dir, "index.html");

const TIPOS_MOV = ["gasto", "ingreso", "transferencia_enviada", "transferencia_recibida"];
const MOMENTOS = ["desayuno", "almuerzo", "merienda", "cena", "colacion"];
const FECHA = /^\d{4}-\d{2}-\d{2}$/;
const VISIBLES = new Set([".jpg", ".jpeg", ".png", ".webp", ".gif", ".pdf"]);

const db = new Database(DB_PATH, { strict: true });
db.exec("PRAGMA foreign_keys = ON");
db.exec("PRAGMA busy_timeout = 5000");

class HttpError extends Error {
  constructor(public status: number, msg: string) {
    super(msg);
  }
}

const json = (data: unknown, status = 200) => Response.json(data, { status });

function fecha(v: unknown, campo: string): string {
  if (typeof v !== "string" || !FECHA.test(v)) throw new HttpError(400, `${campo}: fecha inválida (AAAA-MM-DD)`);
  return v;
}

function texto(v: unknown, campo: string, requerido = false): string | null {
  if (v === undefined || v === null || (typeof v === "string" && v.trim() === "")) {
    if (requerido) throw new HttpError(400, `Falta ${campo}`);
    return null;
  }
  if (typeof v !== "string") throw new HttpError(400, `${campo}: texto inválido`);
  return v.trim().slice(0, 500);
}

function id(v: string): number {
  const n = Number(v);
  if (!Number.isInteger(n) || n <= 0) throw new HttpError(400, "id inválido");
  return n;
}

async function cuerpo(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    if (b && typeof b === "object") return b as Record<string, unknown>;
  } catch {}
  throw new HttpError(400, "JSON inválido");
}

// Sin login, así que al menos que otra página abierta en el navegador no pueda escribir:
// las escrituras tienen que ser JSON y, si viene Origin, del mismo host.
function chequearEscritura(req: Request, url: URL) {
  if (!(req.headers.get("content-type") ?? "").includes("application/json")) throw new HttpError(415, "Se espera JSON");
  const origin = req.headers.get("origin");
  if (origin && new URL(origin).host !== url.host) throw new HttpError(403, "Origen no permitido");
}

// ---------- Gastos ----------

function movimientos(q: URLSearchParams) {
  const params: Record<string, string> = { desde: fecha(q.get("desde"), "desde"), hasta: fecha(q.get("hasta"), "hasta") };
  const tipos = (q.get("tipos") ?? "gasto,transferencia_enviada").split(",").filter((t) => TIPOS_MOV.includes(t));
  if (!tipos.length) return [];
  tipos.forEach((t, i) => (params[`t${i}`] = t));
  const anulados = q.get("anulados") === "1" ? "" : "AND anulado = 0";
  return db
    .query(
      `SELECT id, fecha, tipo, monto, moneda, categoria, contraparte, medio, descripcion, mensaje_original,
              comprobante IS NOT NULL AS tiene_comprobante, anulado, anulado_motivo, creado, actualizado
       FROM movimientos
       WHERE fecha BETWEEN $desde AND $hasta AND tipo IN (${tipos.map((_, i) => `$t${i}`).join(",")}) ${anulados}
       ORDER BY fecha, id`,
    )
    .all(params);
}

function comprobante(movId: number): Response {
  const row = db.query("SELECT comprobante FROM movimientos WHERE id = $id").get({ id: movId }) as { comprobante: string | null } | null;
  if (!row?.comprobante) throw new HttpError(404, "Sin comprobante");
  let real: string;
  try {
    real = realpathSync(resolve(BASE, row.comprobante));
  } catch {
    throw new HttpError(404, "Archivo no encontrado");
  }
  if (!real.startsWith(realpathSync(COMPROBANTES) + sep)) throw new HttpError(403, "Ruta fuera de comprobantes");
  // Fotos y PDF se ven en el navegador. Cualquier otra cosa (un HTML o SVG que llegue por Telegram)
  // se descarga, para que nunca corra scripts en este origen.
  const headers: Record<string, string> = { "X-Content-Type-Options": "nosniff" };
  if (!VISIBLES.has(extname(real).toLowerCase())) headers["Content-Disposition"] = "attachment";
  return new Response(Bun.file(real), { headers });
}

// ---------- Menú ----------

const PLATOS_SQL = `
  SELECT p.id, p.nombre, p.tipo, p.etiquetas, p.notas, p.activo,
         (SELECT MAX(fecha) FROM comidas c WHERE c.plato_id = p.id) AS ultima_vez,
         CAST(julianday(date('now','localtime')) -
              julianday((SELECT MAX(fecha) FROM comidas c WHERE c.plato_id = p.id)) AS INTEGER) AS dias_desde,
         (SELECT COUNT(*) FROM comidas c WHERE c.plato_id = p.id
             AND c.fecha >= date('now','localtime','-30 days')) AS veces_30d
  FROM platos p
  ORDER BY p.activo DESC, p.nombre COLLATE NOCASE`;

function etiquetas(v: string | null): string | null {
  if (!v) return null;
  const lista = [...new Set(v.split(",").map((e) => e.trim().toLowerCase()).filter(Boolean))];
  return lista.length ? lista.join(",") : null;
}

function datosPlato(b: Record<string, unknown>) {
  return {
    nombre: texto(b.nombre, "el nombre del plato", true),
    tipo: texto(b.tipo, "tipo"),
    etiquetas: etiquetas(texto(b.etiquetas, "etiquetas")),
    notas: texto(b.notas, "notas"),
  };
}

// ---------- Comidas ----------

function datosComida(b: Record<string, unknown>) {
  const momento = texto(b.momento, "el momento", true)!;
  if (!MOMENTOS.includes(momento)) throw new HttpError(400, "Momento inválido");
  let platoId: number | null = null;
  if (b.plato_id !== null && b.plato_id !== undefined && b.plato_id !== "") platoId = id(String(b.plato_id));
  let descripcion = texto(b.descripcion, "descripción");
  if (!descripcion && platoId) {
    const p = db.query("SELECT nombre FROM platos WHERE id = $id").get({ id: platoId }) as { nombre: string } | null;
    descripcion = p?.nombre ?? null;
  }
  if (!descripcion) throw new HttpError(400, "Falta qué comiste (elegí un plato o escribí una descripción)");
  return { fecha: fecha(b.fecha, "fecha"), momento, plato_id: platoId, descripcion };
}

// ---------- Rutas ----------

async function rutear(req: Request, url: URL): Promise<Response> {
  const { pathname: p } = url;
  const m = req.method;
  let r: RegExpMatchArray | null;

  if (m === "GET" && p === "/") return new Response(Bun.file(INDEX), { headers: { "Content-Type": "text/html; charset=utf-8" } });
  if (m === "GET" && p === "/api/movimientos") return json(movimientos(url.searchParams));
  if (m === "GET" && (r = p.match(/^\/api\/comprobante\/(\d+)$/))) return comprobante(id(r[1]));

  if (m === "GET" && p === "/api/platos") return json(db.query(PLATOS_SQL).all());
  if (m === "POST" && p === "/api/platos") {
    chequearEscritura(req, url);
    const d = datosPlato(await cuerpo(req));
    return json(db.query("INSERT INTO platos(nombre,tipo,etiquetas,notas) VALUES ($nombre,$tipo,$etiquetas,$notas) RETURNING id").get(d), 201);
  }
  if (m === "PUT" && (r = p.match(/^\/api\/platos\/(\d+)$/))) {
    chequearEscritura(req, url);
    const b = await cuerpo(req);
    const res = db
      .query(
        `UPDATE platos SET nombre=$nombre, tipo=$tipo, etiquetas=$etiquetas, notas=$notas, activo=$activo,
                actualizado=datetime('now','localtime') WHERE id=$id`,
      )
      .run({ ...datosPlato(b), activo: b.activo ? 1 : 0, id: id(r[1]) });
    if (!res.changes) throw new HttpError(404, "Plato no encontrado");
    return json({ ok: true });
  }

  if (m === "GET" && p === "/api/comidas") {
    const q = url.searchParams;
    return json(
      db
        .query(
          `SELECT c.id, c.fecha, c.momento, c.plato_id, p.nombre AS plato, c.descripcion, c.mensaje_original
           FROM comidas c LEFT JOIN platos p ON p.id = c.plato_id
           WHERE c.fecha BETWEEN $desde AND $hasta
           ORDER BY c.fecha DESC,
             CASE c.momento WHEN 'cena' THEN 1 WHEN 'merienda' THEN 2 WHEN 'almuerzo' THEN 3
                            WHEN 'colacion' THEN 4 ELSE 5 END, c.id DESC`,
        )
        .all({ desde: fecha(q.get("desde"), "desde"), hasta: fecha(q.get("hasta"), "hasta") }),
    );
  }
  if (m === "POST" && p === "/api/comidas") {
    chequearEscritura(req, url);
    const d = datosComida(await cuerpo(req));
    return json(db.query("INSERT INTO comidas(fecha,momento,plato_id,descripcion) VALUES ($fecha,$momento,$plato_id,$descripcion) RETURNING id").get(d), 201);
  }
  if (m === "PUT" && (r = p.match(/^\/api\/comidas\/(\d+)$/))) {
    chequearEscritura(req, url);
    const d = datosComida(await cuerpo(req));
    const res = db
      .query("UPDATE comidas SET fecha=$fecha, momento=$momento, plato_id=$plato_id, descripcion=$descripcion WHERE id=$id")
      .run({ ...d, id: id(r[1]) });
    if (!res.changes) throw new HttpError(404, "Comida no encontrada");
    return json({ ok: true });
  }
  if (m === "DELETE" && (r = p.match(/^\/api\/comidas\/(\d+)$/))) {
    chequearEscritura(req, url);
    const res = db.query("DELETE FROM comidas WHERE id=$id").run({ id: id(r[1]) });
    if (!res.changes) throw new HttpError(404, "Comida no encontrada");
    return json({ ok: true });
  }

  throw new HttpError(404, "No encontrado");
}

Bun.serve({
  hostname: HOST,
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    try {
      return await rutear(req, url);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      const msg = String((e as Error)?.message ?? e);
      if (msg.includes("UNIQUE")) return json({ error: "Ya existe un plato con ese nombre" }, 409);
      if (msg.includes("FOREIGN KEY")) return json({ error: "El plato elegido no existe" }, 400);
      if (msg.includes("CHECK")) return json({ error: `Dato inválido (${msg})` }, 400);
      console.error(req.method, url.pathname, e);
      return json({ error: "Error interno, mirá journalctl -u asistente-web" }, 500);
    }
  },
});

console.log(`Tablero en http://${HOST}:${PORT} (base: ${DB_PATH})`);
