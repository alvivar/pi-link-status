# PLAN — pi_link_status (v1)

App Flutter de escritorio que vive en el system tray y muestra el estado del fleet
de terminales pi-link. Target principal **Windows 11**; macOS/Linux deben compilar
y funcionar razonablemente sin trabajo extra.

Filosofía obligatoria para todo el código: **simple, performante, legible,
idiomático; cada línea justificada; abstracciones solo cuando son esenciales.**
Sin state management, sin `package:http`, sin capas de servicio. Dos dependencias
de runtime (`tray_manager`, `window_manager`) y una de desarrollo (`image`, solo
para generar iconos).

- Toolchain: Flutter 3.47.2 stable · Dart 3.13.2 (sealed classes, patterns, records OK).
- Repo: `C:\AERO\me\code\pi_link_status`, rama `master`, **sin commits** al inicio.
- Baseline **pendiente de verificar**: el implementador debe comprobar el estado Git,
  ejecutar `flutter analyze` y `flutter build windows --debug` antes de T0. No hay tests
  todavía: registrar explícitamente `tests: N/A — scaffold sin tests`, no «tests verdes».
  T1 añade los primeros tests útiles; desde T1 el gate completo es obligatorio (§Gate).
- Los números de línea son aproximados; relocaliza por anchor.
- Este plan fija comportamientos, invariantes y pruebas, no presupuestos de líneas ni
  implementaciones para copiar. Elegir firmas y detalles idiomáticos simples al leer las
  APIs reales; declarar cualquier desviación material de comportamiento o alcance.

---

## Fuente de datos (contrato externo — no lo inventes, no lo amplíes)

pi-link 0.4.0 expone `GET http://127.0.0.1:9900/status` (HTTP plano, sin auth,
localhost). Documentado en
`C:\Users\andre\.pi\agent\npm\node_modules\pi-link\README.md` §"Who is connected
right now". Implementación de referencia del cliente:
`C:\Users\andre\.pi\agent\npm\node_modules\pi-link\bin\pi-link.mjs` (funciones
`isStatusPayload`, `failNoHub`, `failUnsupported`, ~líneas 620-700). **Léelas.**

Payload (200 OK):

```json
{
  "hub": "opus@pi-link",
  "port": 9900,
  "terminals": [
    { "name": "opus@pi-link", "role": "hub", "status": "idle", "sinceSeconds": 420,
      "cwd": "C:/Users/andre/my-project", "context": { "tokens": 92000, "window": 272000 } },
    { "name": "gpt@pi-link", "role": "client", "status": "tool:link_send", "sinceSeconds": 3,
      "cwd": "C:/Users/andre/my-project", "context": { "tokens": null, "window": 272000 } },
    { "name": "new@pi-link", "role": "client", "context": null }
  ]
}
```

Reglas del contrato que la app DEBE respetar:

| Regla | Consecuencia |
|---|---|
| `hub` string, `port` number, `terminals` array no vacío; `terminals[0]` es el hub | Si no cumple → payload inválido → estado `Unsupported` |
| `status` + `sinceSeconds` son un par opcional: ambos o ninguno | Ausentes = **desconocido**, se renderiza `?`. **Nunca** sustituir por `idle` |
| `status` es string libre: `idle`, `thinking`, `compacting`, `tool:<name>`, o valores futuros | Valores no reconocidos se muestran tal cual y cuentan como "no idle" |
| `cwd` puede estar **omitido** | Renderizar `?` |
| `context` siempre presente: `null` (sin snapshot) o `{ tokens: int\|null, window: int }` | `null` → `?`; `tokens: null` → `?/272K` |
| Campos desconocidos | Ignorar, no rechazar |
| `sinceSeconds` es relativo al instante de la respuesta | Guardar `receivedAt` y calcular edad al renderizar: `sinceSeconds + (now - receivedAt)` |

Tres resultados de una consulta, exactamente como el CLI:

| Resultado | Cuándo | Estado en la app |
|---|---|---|
| **Online** | 200 + payload válido | `Online(...)` |
| **NoHub** | connection refused, error de socket, o timeout (conexión o respuesta) | `NoHub` — puede ser transitorio (promoción de hub tarda 2–5 s) |
| **Unsupported** | Respondió algo pero no es 200 con payload válido (p. ej. `426 Upgrade Required` de un hub 0.3.0, o JSON que no cumple) | `Unsupported` — mostrar "actualiza pi-link y reinicia terminales" |

Formatos (idénticos al CLI/README):

- Tokens: `92000 → 92K`, `272000 → 272K`, `1300000 → 1.3M`, `2000000 → 2.0M`. Regla: `≥1_000_000` → un decimal + `M`; `≥1_000` → entero redondeado + `K`; menor → número tal cual.
- Context: `92K/272K (34%)`, con percent = `round(tokens/window*100)`. `tokens: null` → `?/272K`. `context: null` → `?`.
- Duración: `<60 → Ns`, `<3600 → Nm`, resto `Nh` (enteros). Ej: `idle (7m)`, `tool:bash (12s)`.

---

## Diseño

### Estado agregado del fleet (`FleetState`)

| Valor | Regla | Icono |
|---|---|---|
| `offline` | `NoHub` o `Unsupported` | gris |
| `compacting` | Online y algún terminal con `status == "compacting"` | ámbar |
| `busy` | Online y algún terminal con `thinking` o `tool:*` | azul |
| `unknown` | Online, sin trabajo reconocido, y algún status ausente o no reconocido | azul (reutiliza el asset `busy`, no añade iconos) |
| `idle` | Online y **todos** los terminales con `status == "idle"` | verde |

Evaluar en ese orden de prioridad. **Desconocido bloquea la confirmación de idle,
pero no es trabajo observado y no arma la alerta.** Si conviven trabajo reconocido
y estados desconocidos, el trabajo reconocido sí la arma; los desconocidos impiden
confirmar todos idle hasta resolverse. El tooltip distingue desconocidos de trabajando.

El alcance es **toda la red pi-link conectada al hub**, sin filtrar por proyecto.
Mostrar ese alcance en la cabecera: un terminal de otro proyecto también puede
bloquear el estado todos idle.

### Alerta "todos idle"

Necesidad del usuario: saber, sin mirar, cuándo todos los agentes están idle.
El aviso dirá **«Todos los agentes están idle»**, nunca «Trabajo completado»:
estar idle no demuestra que el trabajo haya terminado con éxito. La tabla sigue
mostrando el estado actual si los agentes vuelven a trabajar antes de que el usuario regrese.

- **Regla de disparo:** el fleet estuvo `busy` o `compacting` (trabajo reconocido;
  se "arma") y después se observa `idle` en **2 muestras consecutivas** (aproximadamente
  2–4 s desde la transición con respuestas rápidas y polling cada 2 s, no un plazo exacto).
  Al confirmar, se desarma incluso si está silenciada. No repetir hasta observar nuevo trabajo.
- **Sin duración mínima de trabajo:** no exigir 60 s ni intentar inferir presencia
  del usuario. Un trabajo corto observado también puede haber terminado mientras estaba fuera.
- **`unknown`** reinicia las muestras idle consecutivas, sin armar ni desarmar una
  alerta previamente armada. **`offline` desarma** sin disparar (no es «terminaron»).
- **Baja de un terminal:** comparar los nombres del snapshot Online actual con los del
  anterior, sin depender del orden. Si falta cualquiera (aunque fuera idle), desarmar y
  reiniciar la confirmación **antes de evaluar la muestra actual**. No interpretar la baja
  como finalización. Si aún hay trabajo reconocido en esa muestra, puede armar un ciclo
  nuevo; si solo quedan idle/desconocidos, no se arma. Conservar la hora histórica.
  Una incorporación también reinicia la racha de confirmación para evaluar el conjunto
  nuevo, pero no borra trabajo previamente observado. Un cambio de nombre aparece como
  baja + alta y se trata conservadoramente como baja.
  `offline` borra también el conjunto previo; reconectar ya idle no alerta.
  Solo podemos detectar cambios observados entre polls: una desconexión/reconexión con
  el mismo nombre entre muestras es indistinguible en este contrato.
- **Silenciar** (toggle en menú del tray, sin persistencia): la máquina de estados
  sigue funcionando pero el disparo no abre la ventana. Sigue actualizando «última vez idle».
  Mostrar **«Alertas silenciadas»** en la ventana mientras esté activo; la consulta
  manual sigue disponible. Desactivar silencio no reproduce avisos suprimidos.
- **Presentación:** la ventana de estado aparece sola anclada junto al icono del tray y
  **permanece sin robar el foco** a la aplicación en uso hasta que el usuario la oculte
  (§Ventana). Verificar esta capacidad en los plugins; no asumirla. Caso de uso: el usuario se va,
  los agentes trabajan, al volver ve la ventana abierta con la tabla, la clickea y desaparece.
  Sin auto-hide ni timers de ocultación (el tick de edades es independiente).
- **Rastro persistente:** el icono queda verde y la cabecera de la ventana muestra siempre
  `Última vez todos idle: HH:mm` (hora local, de la sesión; `—` si nunca).

Motivo de no usar notificaciones nativas del SO en v1: cero dependencias nuevas,
comportamiento idéntico en las 3 plataformas, y la tabla completa aparece al instante.
Es aditivo si se quiere después.

### Tray

- Icono: 4 archivos estáticos (§T1). En Windows `.ico`, en macOS/Linux `.png`.
  macOS: **no** usar `isTemplate` (el color ES la señal).
- Tooltip: **≤ 127 caracteres, una línea** (límite de Windows). Contenido:
  `pi-link · 3 online · 1 trabajando` / `pi-link · 3 online · todos idle` /
  `pi-link · sin hub` / `pi-link · hub antiguo (actualiza pi-link)`.
  Contar solo `thinking`/`tool:*`/`compacting` como trabajando; si hay desconocidos,
  indicarlos aparte (p. ej. `pi-link · 3 online · 1 trabajando · 1 desconocido`).
- Menú contextual (click derecho), **sin filas de terminales**: la ventana es la única
  vista detallada del estado.
  ```
  Mostrar            (u "Ocultar" si la ventana está visible)
  [x] Silenciar alertas
  ────────
  Salir
  ```
- **Regla anti-churn:** `setIcon` solo cuando cambia la ruta del asset; `setToolTip`
  solo cuando cambia el string; `setContextMenu` solo cuando cambia el par
  `(muted, windowVisible)`. Sin claves derivadas de terminales ni reconstrucción por reloj.
- Click izquierdo → toggle ventana. En Linux/AppIndicator el click izquierdo puede
  abrir el menú directamente; por eso "Mostrar" está siempre en el menú.

### Ventana de estado

- Frameless, sin taskbar, tamaño fijo ~`420×320` lógicos, `alwaysOnTop`.
- Arranca **oculta** (zero-flash: §T6 en el runner + `waitUntilReadyToShow` sin `show()`).
- Modelo "ventana pegajosa": una vez visible, se queda (`alwaysOnTop`) hasta ocultarla
  explícitamente. **Perder el foco NO la oculta.** Se oculta con cualquiera de:
  **click en cualquier punto de la ventana** (`GestureDetector` raíz, `onTap`), click
  izquierdo en el icono del tray (toggle), o "Ocultar" en el menú del tray (el item
  "Mostrar" pasa a llamarse `Mostrar`/`Ocultar` según `isVisible()`; la clave sigue siendo
  `'show'` y el handler es el toggle). Cerrar (WM_CLOSE / ⌘W) = ocultar. Salir solo desde
  el menú del tray. Pie discreto: **«Click para ocultar»**. El gesto renuncia a seleccionar
  texto; desplazar la lista con rueda o arrastre no debe contar como click para ocultar.
- La apertura automática por alerta **no debe activar la ventana ni quitar el foco**
  al editor/terminal en uso. La apertura manual puede activarla. Si los plugins no
  ofrecen esta capacidad en alguna plataforma, reportar el bloqueo antes de introducir
  dependencias o código nativo adicional; no degradar silenciosamente este requisito.
- **Posición:** verificar las capacidades antes de la integración (§T1a). Si hay bounds
  del tray y área útil del monitor que lo contiene, proponer una posición junto al icono
  (margen ~8 px, arriba o abajo según el espacio) y limitar **ambos ejes** al área útil
  de ese monitor, excluyendo barras del sistema. Las coordenadas negativas son válidas:
  no limitar a `x ≥ 0` ni asumir que el monitor principal contiene el tray.
  Bounds del icono, área útil y tamaño de ventana deben estar en el mismo sistema de
  coordenadas/unidades; no multiplicar todo por el DPR de la ventana a ciegas en DPI mixto.
  Si la ventana no cabe, reducir sus dimensiones al área disponible y mantener scroll.
  Si faltan bounds (Linux) o datos de área útil, usar el centrado provisto por el gestor
  solo si T1a confirma que mantiene la ventana accesible; documentar el fallback.
  Si el stack no permite garantizar visibilidad, reportar BLOCKED: cualquier nueva
  dependencia directa o cambio nativo necesita aprobación, aunque sea un paquete transitivo.
- Contenido: cabecera (`Toda la red pi-link`, `hub`, `N online`,
  `Última vez todos idle: HH:mm`, y `Alertas silenciadas` si aplica). Cuando todos
  están idle, mostrar el texto «Todos los agentes están idle»; no mantenerlo como
  estado actual si vuelven a trabajar.
- Cada terminal ocupa **dos líneas**: nombre, `status (edad)` y contexto en la primera;
  `cwd` acortado (`~/...` si empieza por el home) en la segunda, con tipografía secundaria
  y elipsis si hace falta. Priorizar nombre, estado y contexto: permitir ajuste de la
  primera línea si los textos o la escala de fuente lo requieren, sin overflow horizontal.
  Conservar el formato de contexto completo de §Fuente de datos.
- Cabecera y pie fijos; lista con scroll cuando no quepan los terminales (un `ListView`
  simple dentro de `Expanded` basta). No asumir que diez terminales caben en 320 px.
  Edad recalculada con un tick de 1 s mientras la ventana es visible.
- Estados `NoHub`/`Unsupported`: en lugar de la tabla, un texto explicativo:
  `No hay hub en :9900. Si acabas de cerrar el hub, un cliente se promociona en 2–5 s.` /
  `El hub responde pero no soporta /status — actualiza pi-link y reinicia los terminales.`

### Polling

- Polling **serial**: una consulta inicial inmediata y 2 s de espera después de finalizar
  cada intento. Como máximo una operación de red activa; no solapar consultas.
- Reutilizar un `HttpClient` (keep-alive) en operación normal, con `connectionTimeout`
  de 2 s y **un único presupuesto total de 2 s por intento**, contado desde antes de
  solicitar la conexión hasta completar el body. Incluye conexión, cabeceras y
  lectura/descartado del body, también para respuestas no-200. No son 2 s nuevos por fase.
- Un `.timeout` sobre un Future no cancela la operación subyacente: al expirar hay que
  abortar la solicitud y cancelar/liberar la lectura y recursos pendientes. Si aún no
  existe un request, asegurar que cualquier adquisición tardía queda cancelada/inutilizada.
  Se permite cerrar forzosamente y reemplazar el cliente cuando sea necesario para esa
  cancelación; no crear uno nuevo en cada poll normal. No iniciar el siguiente intento
  dejando operaciones previas en segundo plano.
- Consumir/descartar el body completo en respuestas normales. En timeout o cierre,
  **cancelar, no esperar indefinidamente a drenar**. Timeout en cualquier fase → `NoHub`;
  respuesta completada incompatible → `Unsupported`, según §Fuente de datos.
- Resultado → `ValueNotifier<LinkStatus>`; `receivedAt` se fija al completar la respuesta.
  La deduplicación de icono/tooltip/menú vive en el tray.
- **Cierre:** detener nuevos intentos, cancelar el activo y la espera programada, y liberar
  recursos/listeners. Después de iniciar `dispose`, ninguna continuación async puede
  publicar estado, volver a iniciar red ni producir errores sin manejar. Cerrar es seguro
  durante conexión, cabeceras, body y espera. Verificar estas garantías en T3.

### Ficheros

```
lib/
  main.dart            arranque y coordinación de window, tray, poller y alerta
  link_status.dart     modelo, parseo, formatos y FleetState
  poller.dart          polling HTTP y lifecycle → ValueNotifier<LinkStatus>
  idle_alert.dart      máquina de estados pura, con seguimiento de miembros
  tray.dart            icono/tooltip/menú (dedupe) y eventos
  status_window.dart   presentación del estado
tool/
  gen_icons.dart       genera assets/tray/*.png y *.ico
assets/tray/           offline|idle|busy|compacting .png + .ico (commiteados)
test/
  tray_assets_test.dart
  link_status_test.dart
  poller_test.dart
  idle_alert_test.dart
  status_window_test.dart
docs/
  desktop-feasibility.md           resultados de la comprobación temprana T1a
windows/runner/main.cpp            mutex de instancia única
windows/runner/flutter_window.cpp  quitar Show() automático
macos/Runner/Info.plist            LSUIElement
macos/Runner/AppDelegate.swift     no terminar al cerrar última ventana
```

---

## Gate (ejecutado por el implementador)

**Pre-flight y T0:** `git status --short --branch`, `flutter analyze` y
`flutter build windows --debug`. Confirmar si existen tests: en el scaffold descrito
no existen, por lo que la única excepción aprobada es `tests: N/A — aún no hay tests`.
No ejecutar `flutter test` vacío y presentar su fallo como verde. Si aparecen tests
preexistentes, ejecutarlos; si el build/análisis/tests existentes fallan, detener el run
antes de T0 y reportar al usuario. Ningún resultado baseline se presume ejecutado.

**Desde T1, sin excepciones:** T1 incorpora tests reales de los assets y todas las
siguientes tareas deben pasar:

```
flutter analyze
flutter test
flutter build windows --debug
```

El implementador ejecuta y reporta los tres tras cada tarea, incluso T1a (documentación
con prueba de viabilidad). El build Windows sigue siendo obligatorio en tareas Dart.
Cada **Verify** añade comprobaciones manuales; reportar evidencia y qué no se pudo
verificar, sin equiparar análisis de fuente a prueba ejecutada. Una comprobación crítica
no disponible requiere HOLD del usuario, no aprobación automática. Las pruebas macOS/Linux
no ejecutables aquí se registran como pendientes; no se promete soporte validado.
No detener ni alterar terminales/hub del usuario para probar: usar fixtures o servidores
aislados en puertos efímeros salvo consentimiento explícito.

---

## Tareas

### T0 — Commit baseline del scaffold (committer, no implementador)

- **Where:** todo el repo. Estado actual: `## No commits yet on master`, todo untracked.
- **Problem:** sin baseline, `git diff` de la T1 incluiría el scaffold entero y la review
  no sería por tarea.
- **Fix:** después de que el implementador reporte el baseline aprobado en §Gate,
  el committer confirma que no hay staging preexistente y añade **solo rutas explícitas**
  del scaffold: `.gitignore`, `.metadata`, `.vscode/`, `README.md`,
  `analysis_options.yaml`, `lib/`, `linux/`, `macos/`, `pubspec.yaml`, `pubspec.lock`,
  `windows/`. Comparar esta lista con el estado real antes de proceder; dirt inesperado
  → BLOCKED, no limpiar ni incluir. No usar `git add -A`.
  Verificar que `.gitignore` excluye `build/`, `.dart_tool/`, `.idea/`, `*.iml`.
  Inspeccionar `git diff --cached --name-only` antes del commit
  `chore: flutter desktop scaffold`. **No** incluir `PLAN.md` ni `LEDGER-*.md`;
  son documentos del orquestador y dirt esperado durante el run.
- **Risk:** none.
- **Verify:** `git status --short` solo muestra `?? PLAN.md` (y el ledger cuando exista).

### T1 — Dependencias, generador de iconos y assets

- **Where:** `pubspec.yaml`, `pubspec.lock`; nuevo `tool/gen_icons.dart`,
  nuevo dir `assets/tray/`, nuevo `test/tray_assets_test.dart`.
  Se autorizan los registros de plugins generados por Flutter correspondientes a estas deps;
  listar sus rutas exactas en el callback para review y commit.
- **Problem:** el proyecto no tiene deps ni iconos.
- **Fix:**
  1. `pubspec.yaml`:
     ```yaml
     description: "System tray monitor for pi-link terminals."
     dependencies:
       flutter: { sdk: flutter }
       tray_manager: ^0.5.3
       window_manager: ^0.5.2
     dev_dependencies:
       flutter_test: { sdk: flutter }
       flutter_lints: ^6.0.0
       image: ^4.9.2
     flutter:
       uses-material-design: true
       assets:
         - assets/tray/
     ```
     `flutter pub get`.
  2. `tool/gen_icons.dart` (script `dart run tool/gen_icons.dart`): para cada estado
     `{offline: gris 0x9E9E9E, idle: verde 0x43A047, busy: azul 0x1E88E5, compacting: ámbar 0xFFB300}`
     dibuja un círculo relleno con antialias sobre fondo transparente en 256×256 (radio ≈ 112,
     margen para que no toque el borde), guarda `assets/tray/<estado>.png`, y genera
     `assets/tray/<estado>.ico` con los tamaños `16, 20, 24, 32, 48, 64, 256` (redimensionar
     con interpolación cúbica/average desde el 256). Usa `package:image` (`Image`, `fillCircle`,
     `copyResize`, `encodePng`, `encodeIcoImages` o equivalente — verifica los nombres exactos
     en la API instalada de `image` 4.9.x). Sin argumentos ni opciones: el script hace una cosa.
  3. Ejecutar el script y **commitear los assets generados** (la build no debe depender del script).
  4. Añadir tests reales en `test/tray_assets_test.dart`: existen y se decodifican los
     ocho assets; PNG 256×256 con transparencia; cada ICO contiene las dimensiones
     requeridas. Usar `image`, ya declarado como dev dependency. Estos tests establecen
     el gate de tests desde T1, sin crear un smoke test del scaffold que T5 invalidaría.
- **Risk:** low.
- **Verify:** `ls assets/tray` muestra 8 ficheros; abrir un `.ico` con el visor de Windows
  y confirmar que tiene múltiples tamaños y transparencia (o `python -c "from PIL import Image; print(Image.open('assets/tray/idle.ico').info)"` si PIL está disponible; si no, inspección visual). Gate verde.

### T1a — Viabilidad desktop antes de la integración (foco y monitores)

- **Where:** APIs y código de las versiones resueltas de `tray_manager` y `window_manager`;
  nuevo `docs/desktop-feasibility.md`. No modificar aún `lib/main.dart` ni los runners.
- **Problem:** no construir la UI para descubrir al final que no puede mostrarse sin
  activar o que queda fuera de pantalla. No asumir firmas ni disponibilidad por plataforma.
- **Fix:** leer las APIs/implementaciones instaladas y probar un harness mínimo temporal
  fuera del árbol de entrega, sin alterar el scaffold ni añadir dependencias permanentes.
  Registrar en el documento: versiones probadas, APIs/archivos concretos, procedimiento,
  resultados observados y limitaciones por plataforma. Preguntas a resolver:
  1. ¿Cómo mostrar una ventana `alwaysOnTop` sin activarla? Probar en Windows mientras
     se escribe en otro programa, desde ventana oculta y tras hide/show repetidos.
  2. ¿Cómo obtener el área útil del monitor del tray, en qué unidades viene cada rect
     y qué sucede con DPI mixto y monitores en coordenadas negativas?
  3. ¿Qué centrado ofrece el gestor si no hay bounds? Confirmar que la ventana queda
     accesible; si no se puede anclar con las dos dependencias, documentar esa limitación.
  No importar directamente un paquete transitivo sin declararlo. Si hace falta otra
  dependencia o código nativo, reportar BLOCKED con la alternativa mínima y esperar
  aprobación/amendment del plan. Un workaround no se introduce por cuenta propia.
- **Risk:** medium; tarea de viabilidad, no arquitectura adicional.
- **Verify:** gate completo sobre el proyecto entregable. Evidencia de no robo de foco
  en Windows obligatoria antes de T5. Probar layouts de monitores disponibles; los no
  disponibles se declaran y se cubren posteriormente con tests de geometría, sin afirmar
  que se han probado físicamente. Soporte macOS/Linux: distinguir fuente inspeccionada
  de ejecución real. Resultado no concluyente en un requisito crítico → HOLD del usuario.
- **Commit:** solo `docs/desktop-feasibility.md`; ningún harness temporal ni cambio de
  producto. Review independiente valida la evidencia contra estos requisitos antes de avanzar.

### T2 — Modelo `LinkStatus` + parseo + formatos + `FleetState` (puro, con tests)

- **Where:** nuevo `lib/link_status.dart`; nuevo `test/link_status_test.dart`.
- **Problem:** no existe el modelo. Es el corazón testeable de la app.
- **Fix:** modelo Dart puro, sin Flutter: `LinkStatus` sealed con `NoHub`,
  `Unsupported` y `Online`; este último contiene hub, terminales y `receivedAt`.
  `Terminal` conserva nombre, rol, status/edad opcionales, cwd opcional y contexto
  nullable. `ContextUsage` conserva tokens nullable y ventana de contexto.
  Parser que lanza `FormatException` para payload incompatible, ignorando campos extra.
  `FleetState` distingue offline, compacting, busy, unknown e idle según §Diseño.
  Helpers puros de formato (`formatTokens`, `formatDuration`, `shortenHome`) y cálculo
  de edad con `now` explícito. `shortenHome` acepta separadores Windows/Unix y respeta
  límites de directorio, no sustituye prefijos parciales de nombres de usuario.
  El implementador elige constructores/firmas idiomáticos; no generar getters ni capas
  que ningún consumidor necesite.
  Validación en `fromJson` = misma que `isStatusPayload` en `pi-link.mjs`: `hub` string,
  `port` number, `terminals` lista no vacía de mapas, cada uno con `name` string y `role`
  string; `status` y `sinceSeconds` ambos presentes o ambos ausentes (si uno solo → inválido);
  `context` es `null` o mapa con `window` int y `tokens` int|null; `cwd` string opcional.
  Campos extra se ignoran. `FleetState` según §Diseño
  (orden: offline → compacting → busy → unknown → idle).
- **Tests obligatorios** (`test/link_status_test.dart`), usando los payloads del README:
  - Payload completo de 3 terminales → parsea; `fleet == busy` (uno en `tool:*`, otro desconocido).
  - `context: null` → `ContextUsage == null`, label `?`.
  - `tokens: null` → `?/272K`.
  - Un terminal sin `status` y el resto idle → `statusLabel == '?'`, `ageSeconds == null`, fleet `unknown`.
  - Status desconocido `"dreaming"` y el resto idle → label `dreaming`, fleet `unknown`.
  - `thinking` o `tool:*` junto a un status ausente/no reconocido → fleet `busy` (trabajo observado).
  - Todos `idle` → `fleet == idle`; uno `compacting` + otro `thinking` → `compacting`.
  - `status` presente sin `sinceSeconds` → `FormatException`. `terminals: []` → `FormatException`.
    `hub` no string → `FormatException`.
  - `formatTokens`: 92000→`92K`, 272000→`272K`, 1300000→`1.3M`, 2000000→`2.0M`, 999→`999`.
  - `formatDuration`: 12→`12s`, 420→`7m`, 7200→`2h`.
  - `ageSeconds`: `sinceSeconds 10`, recibido hace 5 s → 15.
  - `shortenHome('C:/Users/andre/my-project', 'C:\\Users\\andre')` → `~/my-project`.
- **Risk:** low.
- **Verify:** gate verde; `flutter test` reporta todos los tests de arriba.

### T3 — `Poller` y pruebas de red/lifecycle

- **Where:** nuevos `lib/poller.dart`, `test/poller_test.dart`.
- **Problem:** consultar `/status` sin operaciones colgadas, solapamientos ni callbacks
  después del cierre. Son invariantes críticas; no basta una comprobación manual exitosa.
- **Fix:** implementar §Diseño/Polling con `dart:io`, `dart:convert` y
  `ValueNotifier<LinkStatus>` de Flutter foundation. Estado inicial `NoHub`.
  Mantener pequeña la API (arranque, estado observable y cierre); evitar capas de transporte
  genéricas. Endpoint de producto fijo `http://127.0.0.1:9900/status`; se permite inyectar
  URI, intervalo y deadline por constructor para tests, sin configuración de usuario.
  Aplicar el presupuesto total, cancelación real y guardas de cierre descritos en Diseño;
  no copiar un bucle que publique incondicionalmente después de un `await`.
  Mapear timeout/errores de transporte a `NoHub`; HTTP no-200 completado, JSON inválido o
  contrato incompatible a `Unsupported`; payload válido a `Online` con hora de recepción.
  Todo body debe terminar consumido o cancelado, incluso en fallo y `dispose`.
- **Tests obligatorios:** usar `HttpServer`/`ServerSocket` locales aislados en puertos
  efímeros y cerrar fixtures al terminar. Nunca ocupar :9900 ni interrumpir el hub real.
  1. Payload válido → Online; JSON inválido/HTML, contrato inválido y 426 → Unsupported.
  2. Puerto sin listener → NoHub; listener que acepta y no envía cabeceras → timeout NoHub.
  3. Cabeceras 200 seguidas de body que no termina → NoHub al deadline total; lo mismo
     con no-200. Cabeceras tardías + body tardío comparten presupuesto, no suman deadlines.
  4. Tras timeout, el siguiente intento puede tener éxito; no quedan operaciones anteriores
     activas ni se publica un resultado tardío. Demostrar serialización y liberación de
     recursos con observaciones del fixture, no solo con ausencia de excepciones.
  5. Cierre durante adquisición/conexión, espera de cabeceras, lectura/descartado de body
     y espera entre polls: no hay nuevas publicaciones, requests ni errores async sin manejar.
     Si alguna carrera necesita un punto de inyección mínimo, justificarlo en el callback;
     no montar una arquitectura de mocks. Un segundo arranque no crea otro bucle.
- **Risk:** medium — red y lifecycle; revisión centrada en deadlines y cancelación.
- **Verify:** gate completo. Tests con intervalos/deadlines cortos y tolerancias razonables,
  sin depender del número real de agentes. Como smoke test adicional, lectura del hub real
  si está disponible (solo lectura); ausencia del hub no bloquea los tests aislados.
  Reportar las fases cubiertas y cualquier límite de las pruebas explícitamente.

### T4 — `IdleAlert` (máquina de estados pura, con tests)

- **Where:** nuevo `lib/idle_alert.dart`; nuevo `test/idle_alert_test.dart`.
- **Problem:** implementar la regla de disparo de §Diseño/Alerta de forma testeable y sin UI.
- **Fix:** máquina de estados Dart pura, sin timers ni UI. Recibe **el snapshot
  `LinkStatus` completo y `now` explícito**, no solo FleetState: necesita comparar miembros.
  Mantiene únicamente armado, racha de idle, nombres anteriores, silencio y última hora
  todos idle. Dos confirmaciones por defecto (se permite parámetro para tests).
  Devuelve si corresponde abrir la alerta; el dueño consulta la hora histórica.
  Orden obligatorio por muestra:
  1. NoHub/Unsupported: desarmar, resetear racha y miembros; conservar hora histórica.
  2. Online: comparar conjuntos de nombres. Baja → desarmar y resetear racha;
     alta sin baja → resetear racha conservando armado. Guardar conjunto actual.
  3. Evaluar el fleet actual: busy/compacting arma y borra racha; unknown solo borra
     racha; idle suma una confirmación. Así trabajo reconocido de los supervivientes
     puede armar un **nuevo** ciclo en la misma muestra que una baja.
  4. Al alcanzar las confirmaciones: actualizar última hora todos idle; si estaba
     armado, consumir la alerta y devolver true solo si no está silenciada.
     Idle sostenido no vuelve a actualizar la hora ni avisa otra vez.
  La primera muestra Online no es una baja; arranque ya idle registra la confirmación
  histórica sin alertar. Mute nunca altera el seguimiento de miembros ni el debounce.
- **Tests obligatorios:** las secuencias de fleet siguientes son snapshots con miembros
  estables salvo indicación contraria; ejercitar el método público con snapshots completos.
  - `busy, idle, idle` → `[false, false, true]`.
  - `busy, idle, busy, idle, idle` → último `true`, los demás `false`.
  - `idle, idle, idle` (arranque ya idle, nunca armado) → todo `false`, pero `lastAllIdle` se fija en la 2ª.
  - `busy, offline, idle, idle` → todo `false` (offline desarma).
  - `busy, idle, idle` con `muted = true` → todo `false`, `lastAllIdle` fijado.
  - `busy, idle, idle, idle, idle` → solo un `true`.
  - `confirmations: 1`: `busy, idle` → `true` en la 2ª.
  - `unknown, idle, idle` → todo false: desconocido no arma.
  - `busy, idle, unknown, idle, idle` → solo el último true: desconocido corta la
    confirmación pero conserva el trabajo observado previamente.
  - `compacting, idle, idle` → solo el último true.
  - Un único sample busy, aunque el trabajo dure menos de 60 s, seguido de dos idle → alerta.
  - Tras un aviso silenciado, desactivar `muted` y seguir idle → no hay aviso retroactivo.
  - A trabajando + B idle → desaparece A → B idle dos veces: no alerta, aunque el
    agregado final sea idle. También probar baja de un miembro que ya estaba idle.
  - Baja durante la primera confirmación idle → reinicia y no alerta sin nuevo trabajo.
  - Baja de A dejando B trabajando → dos muestras B idle: sí alerta por el nuevo ciclo.
  - Incorporación durante confirmación → exige dos idle del conjunto nuevo, conservando
    el armado previo. Reordenar miembros sin altas/bajas no reinicia nada.
  - Cambio de nombre (baja + alta) → reset conservador; offline seguido de Online idle
    no recupera un armado viejo. Ningún reset borra la hora histórica.
- **Risk:** low.
- **Verify:** gate verde.

### T5 — Tray, ventana de estado y `main.dart` (wiring con plugins)

- **Where:** nuevos `lib/tray.dart`, `lib/status_window.dart`,
  `test/status_window_test.dart`; reescribir `lib/main.dart`.
  Si la colocación necesita tests puros separados, añadir `test/window_position_test.dart`
  y listar esa ruta en el callback. Sin cambios de dependencias fuera de una enmienda aprobada.
- **Problem:** unir T2–T4 con `tray_manager` y `window_manager` según §Diseño.
- **Prerequisito:** T1a aprobado y `docs/desktop-feasibility.md` con la ruta verificada
  para mostrar sin activar y posicionar dentro de pantalla. No diferir esa investigación a T5.
- **Fix:** Antes de escribir, **lee la API instalada** en
  `%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\tray_manager-0.5.3\lib\` y
  `window_manager-0.5.2\lib\` (nombres exactos de `TrayListener`, `Menu`/`MenuItem`,
  `getBounds`, `WindowOptions`, `waitUntilReadyToShow`, `setPreventClose`, `WindowListener`).
  El plan pinta invariantes, no firmas.

  **`tray.dart`** — `class Tray with TrayListener`:
  - `Future<void> init()`: `trayManager.addListener(this)`; aplica `sync` inicial con `NoHub`.
  - `Future<void> sync(LinkStatus s, {required bool muted, required bool windowVisible})`:
    calcula la ruta del icono y el tooltip. Llama a `setIcon`/`setToolTip` **solo** cuando
    cambia el valor aplicado. `iconPath` = `assets/tray/<asset>.${Platform.isWindows ? 'ico' : 'png'}`;
    `<asset>` corresponde al fleet salvo `unknown`, que reutiliza `busy`.
    El menú solo contiene Mostrar/Ocultar, Silenciar alertas y Salir (§Diseño/Tray).
    Guardar el último par `(muted, windowVisible)` aplicado: solo sus cambios regeneran
    el menú. Sin filas de terminales ni `menuKey` derivado del snapshot.
  - Callbacks: `onTrayIconMouseDown` → `onToggleWindow()`; `onTrayIconRightMouseDown` →
    `trayManager.popUpContextMenu()`; `onTrayMenuItemClick(item)` por `key`:
    `'show'` → `onToggleWindow()`, `'mute'` → `onToggleMute()`, `'quit'` → `onQuit()`.
    Las tres son callbacks `VoidCallback` inyectadas por constructor — el tray no conoce
    `windowManager` ni el poller.
  - Tooltip ≤ 127 chars: si el nombre del hub no cabe, no lo incluyas; el resumen numérico basta.

  **`status_window.dart`** — `class StatusView extends StatefulWidget` que recibe
  `ValueListenable<LinkStatus> status`, `ValueListenable<DateTime?> lastAllIdle`,
  `bool muted`, `bool visible` y `VoidCallback onTap`. El dueño reconstruye al cambiar
  silencio o visibilidad; no añadir otro notifier para estos booleanos.
  Tick de 1 s para las edades solo mientras `visible`; cancelar al ocultar y en `dispose`.
  Raíz: `GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap)` — click oculta,
  scroll no. Layout según §Diseño/Ventana: `Material` + `Column`, cabecera fija con alcance,
  estado actual, última vez idle y aviso de silencio; `Expanded` con `ListView` de terminales
  en dos líneas (nombre/estado/contexto y ruta secundaria); pie fijo «Click para ocultar».
  Sin overflow con diez terminales o rutas largas. Números tabulares
  (`FontFeature.tabularFigures`), tema oscuro simple (`ThemeData.dark()`), sin assets de fuentes.
  Sin `MouseRegion`, sin timers de auto-hide.

  **`main.dart`**: inicializar Flutter y el window manager; configurar ventana
  frameless, sin taskbar, siempre encima, inicialmente oculta y con cierre interceptado.
  Usar las APIs verificadas, sin imponer una firma de `WindowOptions` de memoria.
  `App` es el dueño único del Poller, IdleAlert, Tray, última hora idle y visibilidad.
  - Arranque ordenado: registrar listeners e inicializar ventana/tray antes de arrancar
    el polling. No lanzar inicializaciones async en paralelo sin controlar sus resultados.
  - Por cada snapshot: pasar **el LinkStatus completo** a IdleAlert con la hora actual
    (la comparación de miembros vive allí, no duplicarla en App); actualizar la hora histórica
    y sincronizar el tray con status, silencio y visibilidad. Si IdleAlert devuelve que
    corresponde alertar y la ventana está oculta, mostrarla automáticamente sin activar.
  - `_show({bool automatic = false})`: posiciona según §Diseño/Ventana
    (bounds/área útil y fallback verificados en T1a), muestra sin activar si `automatic`
    usando la capacidad verificada del plugin; la apertura manual puede activar.
    Actualizar `_visible = true`, reconstruir `StatusView` y re-`sync` del tray.
    Si ya está visible, una alerta actualiza los datos sin volver a mostrar/activar la ventana.
  - `_hide()`: `windowManager.hide()`, actualizar `_visible = false`, reconstruir
    `StatusView` y re-`sync` del tray.
  - Toggle de silencio: invertir `alert.muted`, reconstruir `StatusView` para reflejar
    «Alertas silenciadas» y re-`sync` del tray. No ocultar la ventana ni emitir avisos retroactivos.
  - `onWindowClose` → `_hide()` (con `preventClose` activo no cierra). **No** escuchar `onWindowBlur`.
  - Toggle (tray click izquierdo, item Mostrar/Ocultar): `_visible ? _hide() : _show()`.
  - `StatusView.onTap` → `_hide()`.
  - Quit: impedir nuevos callbacks/acciones, desregistrar listeners, detener y liberar
    el poller según T3, liberar timers/notifiers del dueño y destruir tray/ventana de
    forma ordenada. Comprobar que el proceso termina; no usar `exit(0)` para ocultar
    carreras o errores de cleanup. Serializar las operaciones nativas async de visibilidad
    y tray para que clicks/polls consecutivos no apliquen estado viejo fuera de orden.
  - Sin `Provider`, sin `InheritedWidget` propio: `StatusView` recibe los `ValueListenable` por constructor.
- **Invariantes a verificar contra el código de los plugins (no las asumas):**
  1. `waitUntilReadyToShow` sin llamar a `show()` deja la ventana oculta en Windows una vez
     aplicado T6. Si el plugin necesita `hide()` explícito en el callback, añadirlo y anotarlo.
  2. `setPreventClose(true)` hace que `onWindowClose` se dispare y la ventana **no** se destruya.
  3. Aplicar la conversión y el origen por monitor verificados en T1a: ventana íntegra
     en el área útil, también con origen negativo y DPI mixto. No usar un DPR global
     como solución automática. Una limitación nueva respecto a T1a → BLOCKED.
  4. `onTrayIconMouseDown` se dispara con click izquierdo en Windows sin `popUpContextMenu`.
  5. Mostrar automáticamente con `alwaysOnTop` no activa la ventana ni roba el foco.
     Leer la API/implementación instalada para identificar la opción correspondiente y
     verificar escribiendo en otra aplicación. Si no está soportado, reportar BLOCKED
     antes de ampliar alcance con código nativo o dependencias adicionales.
- **Risk:** medium — es la tarea más grande y wirea dos plugins. El implementador entra con ventana compactada.
- **Verify:** gate verde. Manual en Windows (`flutter run -d windows`), usando snapshots
  controlados o un hub de prueba aislado para las transiciones. No asumir que un nuevo
  terminal es el único conectado ni detener la red que sostiene este run.
  1. Al arrancar: aparece icono gris en el tray, **ninguna ventana** (con T6 aplicado; sin T6 puede haber flash — anotar).
  2. Con un snapshot de un único terminal idle → icono verde al siguiente poll;
     tooltip `pi-link · 1 online · todos idle`. Sin alerta al arrancar ya idle.
  3. Click izquierdo en el icono → ventana junto al tray con la fila del terminal y edad subiendo cada segundo. Click en otra aplicación → **sigue visible**. Click dentro de la ventana → se oculta. Click en el icono → aparece; click en el icono otra vez → se oculta.
  4. Click derecho → menú solo con Mostrar/Ocultar, Silenciar alertas y Salir, sin filas
     de terminales. Los cambios de estado/contexto no regeneran el menú.
  5. Con la ventana oculta, observar trabajo y luego dos muestras todos idle → la ventana
     aparece sola, dice «Todos los agentes están idle», registra la hora y **permanece**.
     Seguir escribiendo en otra aplicación durante el aviso: el foco y el texto permanecen
     allí. Probar también trabajo observado de menos de 60 s; no hay duración mínima.
  6. Silenciar → abrir manualmente: aparece «Alertas silenciadas». Ocultar y repetir 5:
     icono cambia, ventana no aparece, la hora se actualiza al consultarla manualmente.
     Desactivar silencio estando todos idle no reproduce el aviso.
  7. Con diez terminales y nombres/rutas largos: cabecera y «Click para ocultar» siguen
     visibles, no hay overflow, la lista permite llegar al último terminal. Rueda y arrastre
     desplazan sin ocultar; un click sí oculta. La cabecera indica «Toda la red pi-link».
     Usar fixtures para reproducir estos datos si no están disponibles en la red real.
  8. Mientras la ventana está abierta, volver a observar trabajo: actualizar la tabla y
     el estado actual (no seguir afirmando todos idle); conservar la hora histórica.
  9. Salir → el proceso termina (comprobar en Task Manager).
  Añadir tests de widget para silencio visible, texto de alcance, lista con diez terminales,
  ausencia de overflow, scroll sin cierre y click con cierre. Si hay cálculo de colocación
  propio, probarlo como función pura con áreas útiles de origen negativo, borde derecho,
  barra superior/inferior y área menor que el tamaño preferido. Ejecutar en los monitores
  y escalas disponibles; registrar los casos solo simulados. Confirmar también con fixture
  que una baja que deja el resto idle no abre alerta. Reportar literalmente las comprobaciones
  manuales realizadas; las no verificables deben declararse, no presumirse.

### T6 — Runner Windows: instancia única + arranque oculto (**sensible, serializada**)

- **Where:** `windows/runner/main.cpp` (`wWinMain`, tras `CoInitializeEx`, ~línea 18);
  `windows/runner/flutter_window.cpp` (`FlutterWindow::OnCreate`, callback `SetNextFrameCallback`, ~línea 31).
- **Problem:** (a) dos copias del tray app = dos iconos; (b) el runner llama `this->Show()` al primer
  frame → flash de la ventana antes de que Dart pueda ocultarla.
- **Fix:**
  (a) En `main.cpp`, antes de crear el engine/ventana, adquirir un named mutex estable
  para la app y mantener su handle durante toda la vida del proceso. Si ya existe,
  salir sin crear ventana/tray; si la adquisición falla por otro motivo, reportar fallo,
  no simular un segundo lanzamiento correcto. Liberar handles y equilibrar COM en
  las salidas correspondientes. No activar la instancia existente (fuera de alcance v1).
  (b) En `flutter_window.cpp`, revisar `OnCreate` y el callback que ejecuta `this->Show()`.
  Suprimir el show automático siguiendo la receta de la versión resuelta de
  `window_manager`; preservar lo necesario para que el primer frame y el show manual
  funcionen. No dejar callbacks vacíos sin finalidad. Verificar que `CreateWindow`
  ya nace sin visibilidad en el runner real; no aplicar cambios nativos de memoria.
- **Invariante:** con T5 + T6, el proceso arranca sin ninguna ventana visible en ningún momento,
  y `windowManager.show()` posterior funciona. `SetQuitOnClose(true)` se mantiene (con
  `preventClose` en Dart el WM_CLOSE nunca llega a destruir).
- **Risk:** medium/high — C++ nativo, verificación solo visual. Ventana compactada antes de empezar.
- **Verify:** gate verde (la build es el compilador). Manual: `flutter run -d windows` 3 veces →
  cero flash. Lanzar el `.exe` de `build\windows\x64\runner\Debug\` dos veces → un solo icono en
  el tray, el segundo proceso no aparece en Task Manager. Cerrar por "Salir" y relanzar → arranca (mutex liberado).

### T7 — macOS: agente sin Dock (no verificable en esta máquina)

- **Where:** `macos/Runner/Info.plist` (dentro del `<dict>` raíz); `macos/Runner/AppDelegate.swift:6-8`.
- **Problem:** sin `LSUIElement` la app aparece en el Dock; y `applicationShouldTerminateAfterLastWindowClosed`
  devuelve `true` → ocultar la ventana mataría la app.
- **Fix:** añadir
  ```xml
  <key>LSUIElement</key>
  <true/>
  ```
  y cambiar el `return true` a `return false` en `AppDelegate.swift`.
- **Risk:** low (no compila aquí; cambios declarativos mínimos).
- **Verify:** gate verde en Windows (no afectado). Inspección: el plist sigue siendo XML válido
  (`python -c "import plistlib;plistlib.load(open('macos/Runner/Info.plist','rb'))"`). Marcar en el
  ledger como **no verificado en macOS**.

---

## Sequencing

| Orden | Tarea | Riesgo | Notas de orquestación |
|---|---|---|---|
| Pre | Baseline | low | implementador verifica Git + analyze + build; tests N/A solo si no existen; HOLD si rojo |
| 0 | T0 baseline commit | none | committer, solo scaffold explícito, tras baseline aprobado |
| 1 | T1 deps + iconos + tests de assets | low | desde aquí gate completo obligatorio |
| 2 | T1a viabilidad de foco/monitores | medium | implementar prueba → review de evidencia → commit del informe; BLOCKED si no es viable |
| 3 | T2 modelo + tests | low | puro; el reviewer comprueba el contrato |
| 4 | T4 IdleAlert + miembros + tests | low | puro; bajas nunca se interpretan como fin del trabajo |
| 5 | T3 Poller + tests de red | medium | deadline integral, cancelación y cierre |
| 6 | T5 tray + ventana + main | medium | **compactar implementador antes**; T1a ya aprobado |
| 7 | T6 runner Windows | medium/high | **sensible, serializada**; compactar antes; desacuerdos → usuario |
| 8 | T7 macOS | low | declarativo; ejecución macOS pendiente |

Orden fijo, serial y con commit antes de la siguiente implementación. T5 puede verificar
la interacción, pero el arranque zero-flash final se acepta en T6 con T5 ya integrado.
No cambiar el orden por disponibilidad de contexto; compactar en las fronteras apropiadas.
Gate según §Gate: excepción explícita de scaffold sin tests solo en pre-flight/T0;
desde T1 `flutter analyze && flutter test && flutter build windows --debug`.

Commit por tarea, mensajes en inglés, imperativo, prefijo convencional:
`chore: flutter desktop scaffold` · `build: add tray/window deps and tray icons` ·
`docs: verify desktop focus and positioning feasibility` ·
`feat: LinkStatus model, parsing and formats` · `feat: IdleAlert state machine` ·
`feat: Poller for /status` · `feat: tray, status window and app wiring` ·
`feat(windows): single instance and hidden launch` · `feat(macos): run as agent app`.
`PLAN.md` se commitea al final del run (`docs: add v1 plan`), o se borra si el usuario prefiere.

---

## Out of scope (v1) — no hacer

- Notificaciones nativas del SO (`local_notifier`). Aditivo para v2 si se quiere rastro en el centro de notificaciones.
- WebSocket / protocolo pi-link. La API HTTP `/status` es la estable y documentada.
- Enviar mensajes, compactar, o cualquier acción sobre los terminales. Solo lectura.
- Puerto configurable, settings, persistencia de "silenciar". Sin ficheros de config.
- Filtros por proyecto/cwd: v1 observa toda la red conectada al hub.
- Duración mínima de trabajo o detección de presencia/inactividad del usuario: sin heurísticas.
- Refinamientos de iconos: `unknown` reutiliza el azul, pero se distingue en los textos.
- `launch_at_startup`. Se añade después si el usuario lo pide.
- Activar la instancia existente al lanzar una segunda (`windows_single_instance`). El mutex basta.
- Migrar a `nativeapi-flutter` (anunciado por leanflutter): inmaduro; no en v1.
- Linux: no hay `getBounds` ni tooltip en AppIndicator; el click izquierdo puede abrir el menú. Se
  acepta la degradación ("Mostrar" en el menú, ventana centrada). No intentar workarounds.
- Iconos `isTemplate` en macOS: descartado, el color es la señal.
- Info-only: Flutter 3.47.2 trae Dart 3.13.2 (no 3.12); `pubspec.yaml` ya tiene `sdk: ^3.12.2`, compatible. No tocar.
