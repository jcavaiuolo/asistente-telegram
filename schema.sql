-- Esquema del asistente personal (SQLite)
-- Se aplica con: bin/db < schema.sql   (es idempotente)

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ============================================================
-- FINANZAS
-- ============================================================

CREATE TABLE IF NOT EXISTS movimientos (
  id               INTEGER PRIMARY KEY,
  fecha            TEXT NOT NULL CHECK (fecha GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  tipo             TEXT NOT NULL CHECK (tipo IN ('gasto','ingreso','transferencia_enviada','transferencia_recibida')),
  monto            REAL NOT NULL CHECK (monto > 0),
  moneda           TEXT NOT NULL DEFAULT 'ARS' CHECK (moneda IN ('ARS','USD')),
  categoria        TEXT,               -- ver lista sugerida en CLAUDE.md
  contraparte      TEXT,               -- comercio o persona
  medio            TEXT,               -- efectivo, debito, credito, mercado_pago, transferencia, otro
  descripcion      TEXT,
  mensaje_original TEXT,               -- texto tal cual llegó por Telegram (trazabilidad)
  comprobante      TEXT,               -- ruta al archivo guardado en comprobantes/
  telegram_msg_id  TEXT,
  anulado          INTEGER NOT NULL DEFAULT 0 CHECK (anulado IN (0,1)),
  anulado_motivo   TEXT,
  creado           TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  actualizado      TEXT
);

CREATE INDEX IF NOT EXISTS ix_mov_fecha ON movimientos(fecha);
CREATE INDEX IF NOT EXISTS ix_mov_cat   ON movimientos(categoria);

-- Auditoría: cada cambio sobre un movimiento queda registrado con el antes y el después.
CREATE TABLE IF NOT EXISTS auditoria (
  id        INTEGER PRIMARY KEY,
  tabla     TEXT NOT NULL,
  fila_id   INTEGER NOT NULL,
  accion    TEXT NOT NULL,
  antes     TEXT,
  despues   TEXT,
  cuando    TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TRIGGER IF NOT EXISTS trg_mov_no_delete
BEFORE DELETE ON movimientos
BEGIN
  SELECT RAISE(ABORT, 'No se borran movimientos: usar anulado = 1 con anulado_motivo');
END;

CREATE TRIGGER IF NOT EXISTS trg_mov_insert
AFTER INSERT ON movimientos
BEGIN
  INSERT INTO auditoria(tabla, fila_id, accion, despues)
  VALUES ('movimientos', NEW.id, 'insert',
    json_object('fecha',NEW.fecha,'tipo',NEW.tipo,'monto',NEW.monto,'moneda',NEW.moneda,
                'categoria',NEW.categoria,'contraparte',NEW.contraparte,'medio',NEW.medio,
                'descripcion',NEW.descripcion));
END;

CREATE TRIGGER IF NOT EXISTS trg_mov_update
AFTER UPDATE ON movimientos
BEGIN
  INSERT INTO auditoria(tabla, fila_id, accion, antes, despues)
  VALUES ('movimientos', NEW.id, CASE WHEN NEW.anulado = 1 AND OLD.anulado = 0 THEN 'anulacion' ELSE 'update' END,
    json_object('fecha',OLD.fecha,'tipo',OLD.tipo,'monto',OLD.monto,'moneda',OLD.moneda,
                'categoria',OLD.categoria,'contraparte',OLD.contraparte,'medio',OLD.medio,
                'descripcion',OLD.descripcion,'anulado',OLD.anulado),
    json_object('fecha',NEW.fecha,'tipo',NEW.tipo,'monto',NEW.monto,'moneda',NEW.moneda,
                'categoria',NEW.categoria,'contraparte',NEW.contraparte,'medio',NEW.medio,
                'descripcion',NEW.descripcion,'anulado',NEW.anulado,'motivo',NEW.anulado_motivo));
END;

-- Movimientos vigentes (sin anulados)
CREATE VIEW IF NOT EXISTS v_movimientos AS
  SELECT * FROM movimientos WHERE anulado = 0;

-- Resumen mensual por categoría (solo egresos)
CREATE VIEW IF NOT EXISTS v_gastos_mes AS
  SELECT substr(fecha,1,7) AS mes, moneda, COALESCE(categoria,'sin_categoria') AS categoria,
         COUNT(*) AS cantidad, ROUND(SUM(monto),2) AS total
  FROM movimientos
  WHERE anulado = 0 AND tipo IN ('gasto','transferencia_enviada')
  GROUP BY mes, moneda, categoria
  ORDER BY mes DESC, total DESC;

-- Detalle por producto de los tickets, vinculado a movimientos.
-- Mismo patrón que movimientos: sin DELETE (se anula) y auditoría de altas y cambios.
CREATE TABLE IF NOT EXISTS movimiento_items (
  id              INTEGER PRIMARY KEY,
  movimiento_id   INTEGER NOT NULL REFERENCES movimientos(id),
  fecha           TEXT NOT NULL CHECK (fecha GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  comercio        TEXT,
  descripcion     TEXT NOT NULL,   -- texto tal cual el ticket
  producto        TEXT,            -- nombre normalizado, minúscula, ej. 'queso barra'
  marca           TEXT,
  codigo_barras   TEXT,            -- EAN o código interno del ticket
  cantidad        REAL NOT NULL DEFAULT 1 CHECK (cantidad > 0),
  unidad          TEXT NOT NULL DEFAULT 'un' CHECK (unidad IN ('un','kg','l')),
  precio_unitario REAL NOT NULL CHECK (precio_unitario >= 0),
  descuento       REAL NOT NULL DEFAULT 0 CHECK (descuento >= 0),
  subtotal        REAL NOT NULL,   -- cantidad x precio_unitario - descuento
  moneda          TEXT NOT NULL DEFAULT 'ARS' CHECK (moneda IN ('ARS','USD')),
  anulado         INTEGER NOT NULL DEFAULT 0 CHECK (anulado IN (0,1)),
  creado          TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  actualizado     TEXT
);
CREATE INDEX IF NOT EXISTS ix_items_mov  ON movimiento_items(movimiento_id);
CREATE INDEX IF NOT EXISTS ix_items_prod ON movimiento_items(producto, fecha);
CREATE INDEX IF NOT EXISTS ix_items_ean  ON movimiento_items(codigo_barras, fecha);

CREATE TRIGGER IF NOT EXISTS trg_items_no_delete
BEFORE DELETE ON movimiento_items
BEGIN
  SELECT RAISE(ABORT, 'No se borran items: usar anulado = 1');
END;

CREATE TRIGGER IF NOT EXISTS trg_items_insert
AFTER INSERT ON movimiento_items
BEGIN
  INSERT INTO auditoria(tabla, fila_id, accion, despues)
  VALUES ('movimiento_items', NEW.id, 'insert',
    json_object('movimiento_id',NEW.movimiento_id,'fecha',NEW.fecha,'comercio',NEW.comercio,
                'descripcion',NEW.descripcion,'producto',NEW.producto,'marca',NEW.marca,
                'codigo_barras',NEW.codigo_barras,'cantidad',NEW.cantidad,'unidad',NEW.unidad,
                'precio_unitario',NEW.precio_unitario,'descuento',NEW.descuento,
                'subtotal',NEW.subtotal,'moneda',NEW.moneda));
END;

CREATE TRIGGER IF NOT EXISTS trg_items_update
AFTER UPDATE ON movimiento_items
BEGIN
  INSERT INTO auditoria(tabla, fila_id, accion, antes, despues)
  VALUES ('movimiento_items', NEW.id, CASE WHEN NEW.anulado = 1 AND OLD.anulado = 0 THEN 'anulacion' ELSE 'update' END,
    json_object('movimiento_id',OLD.movimiento_id,'fecha',OLD.fecha,'comercio',OLD.comercio,
                'descripcion',OLD.descripcion,'producto',OLD.producto,'marca',OLD.marca,
                'codigo_barras',OLD.codigo_barras,'cantidad',OLD.cantidad,'unidad',OLD.unidad,
                'precio_unitario',OLD.precio_unitario,'descuento',OLD.descuento,
                'subtotal',OLD.subtotal,'moneda',OLD.moneda,'anulado',OLD.anulado),
    json_object('movimiento_id',NEW.movimiento_id,'fecha',NEW.fecha,'comercio',NEW.comercio,
                'descripcion',NEW.descripcion,'producto',NEW.producto,'marca',NEW.marca,
                'codigo_barras',NEW.codigo_barras,'cantidad',NEW.cantidad,'unidad',NEW.unidad,
                'precio_unitario',NEW.precio_unitario,'descuento',NEW.descuento,
                'subtotal',NEW.subtotal,'moneda',NEW.moneda,'anulado',NEW.anulado));
END;

-- Precios por producto, solo de items y movimientos vigentes.
CREATE VIEW IF NOT EXISTS v_precios_producto AS
SELECT i.producto, i.codigo_barras, i.descripcion, i.marca, i.comercio, i.fecha,
       i.cantidad, i.unidad, i.precio_unitario, i.descuento, i.subtotal, i.moneda,
       i.movimiento_id
FROM movimiento_items i
JOIN movimientos m ON m.id = i.movimiento_id
WHERE i.anulado = 0 AND m.anulado = 0;

-- ============================================================
-- COMIDAS
-- ============================================================

CREATE TABLE IF NOT EXISTS platos (
  id          INTEGER PRIMARY KEY,
  nombre      TEXT NOT NULL UNIQUE COLLATE NOCASE,
  tipo        TEXT,                  -- carne, pollo, pescado, pasta, vegetariano, sopa, otro
  etiquetas   TEXT,                  -- separadas por coma: rapido, horno, parrilla, liviano, finde...
  activo      INTEGER NOT NULL DEFAULT 1 CHECK (activo IN (0,1)),
  notas       TEXT,
  creado      TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  actualizado TEXT
);

CREATE TABLE IF NOT EXISTS comidas (
  id               INTEGER PRIMARY KEY,
  fecha            TEXT NOT NULL CHECK (fecha GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  momento          TEXT NOT NULL CHECK (momento IN ('desayuno','almuerzo','merienda','cena','colacion')),
  plato_id         INTEGER REFERENCES platos(id),   -- NULL si no está en el menú
  descripcion      TEXT NOT NULL,
  mensaje_original TEXT,
  creado           TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE INDEX IF NOT EXISTS ix_comidas_fecha ON comidas(fecha);

CREATE TABLE IF NOT EXISTS sugerencias (
  id        INTEGER PRIMARY KEY,
  fecha     TEXT NOT NULL,
  plato_id  INTEGER REFERENCES platos(id),
  texto     TEXT NOT NULL,
  aceptada  INTEGER CHECK (aceptada IN (0,1)),     -- NULL = sin respuesta todavía
  creado    TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

-- Platos activos con la última vez que se comieron (base para sugerir)
CREATE VIEW IF NOT EXISTS v_platos_rotacion AS
  SELECT p.id, p.nombre, p.tipo, p.etiquetas,
         (SELECT MAX(fecha) FROM comidas c WHERE c.plato_id = p.id) AS ultima_vez,
         CAST(julianday(date('now','localtime')) -
              julianday((SELECT MAX(fecha) FROM comidas c WHERE c.plato_id = p.id)) AS INTEGER) AS dias_desde,
         (SELECT COUNT(*) FROM comidas c WHERE c.plato_id = p.id
             AND c.fecha >= date('now','localtime','-30 days')) AS veces_30d
  FROM platos p
  WHERE p.activo = 1
  ORDER BY (ultima_vez IS NOT NULL), ultima_vez ASC;
