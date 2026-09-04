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
- Baseline de tests: no hay tests todavía → `flutter analyze` limpio sobre el
  scaffold es el baseline. Se crea un commit baseline del scaffold antes de T1 (§Sequencing).
- Los números de línea son aproximados; relocaliza por anchor.

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
| `busy` | Online y algún terminal con `thinking`, `tool:*`, status **desconocido/ausente** o valor no reconocido | azul |
| `idle` | Online y **todos** los terminales con `status == "idle"` | verde |

Evaluar en ese orden de prioridad. Un status desconocido cuenta como `busy`
deliberadamente: es lo conservador y evita disparar la alerta con información
incompleta ("`?` means unknown, not idle").

### Alerta "todos idle"

Necesidad del usuario: saber, sin mirar, cuándo el fleet ha terminado.

- **Regla de disparo:** el fleet estuvo `busy` o `compacting` (se "arma") y después
  se observa `idle` en **2 muestras consecutivas** (debounce ≈ 4 s a 2 s/poll).
  Al disparar, se desarma. Vuelve a armarse en la siguiente muestra `busy`/`compacting`.
- **`offline` desarma** sin disparar (no es "terminaron", es "no hay nadie").
- **Silenciar** (toggle en menú del tray, sin persistencia): la máquina de estados
  sigue funcionando pero el disparo no muestra nada. Sigue actualizando "última vez idle".
- **Presentación:** la ventana de estado aparece sola anclada junto al icono del tray y
  **permanece** hasta que el usuario la oculte (§Ventana). Caso de uso: el usuario se va,
  los agentes trabajan, al volver ve la ventana abierta con la tabla, la clickea y desaparece.
  Sin auto-hide, sin timers.
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
- Menú contextual (click derecho):
  ```
  opus@pi-link · idle · 92K/272K (34%)      (disabled)
  gpt@pi-link · tool:link_send · ?/272K     (disabled)
  new@pi-link · ? · ?                        (disabled)
  ────────
  Mostrar            (u "Ocultar" si la ventana está visible)
  [x] Silenciar alertas
  ────────
  Salir
  ```
  Las filas de terminal **no incluyen la edad** (`(12s)`), para que el menú no
  cambie en cada poll.
- **Regla anti-churn:** `setIcon` solo cuando cambia `FleetState`; `setToolTip`
  solo cuando cambia el string; `setContextMenu` solo cuando cambia la "clave de
  snapshot" (concatenación de las filas de terminal formateadas). Comparar strings,
  no reconstruir por reloj.
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
  el menú del tray.
- Posición al mostrar: si `trayManager.getBounds()` devuelve rect (Windows/macOS) →
  centrar horizontalmente sobre el icono, con `x` clampado a `≥ 0`; `y = top - alto - 8`;
  si `y < 0` (barra de menú arriba, macOS) → `y = bottom + 8`. Si devuelve `null`
  (Linux) → `windowManager.center()`.
- Contenido: cabecera (`hub`, `N online`, `Última vez todos idle: HH:mm`) + una fila por terminal: `name` · `status (edad)` · `context` · `cwd`
  acortado (`~/...` si empieza por el home). Edad recalculada con un tick de 1 s
  mientras la ventana es visible. Sin `ListView` builder ni virtualización: son ≤ 10 filas.
- Estados `NoHub`/`Unsupported`: en lugar de la tabla, un texto explicativo:
  `No hay hub en :9900. Si acabas de cerrar el hub, un cliente se promociona en 2–5 s.` /
  `El hub responde pero no soporta /status — actualiza pi-link y reinicia los terminales.`

### Polling

- Bucle **serial**: `while (!stopped) { await poll(); await Future.delayed(2 s); }`.
  Nunca `Timer.periodic` (solaparía requests).
- Un único `HttpClient` de `dart:io` para toda la vida de la app (keep-alive por defecto).
  `connectionTimeout = 2 s`. Deadline total de 2 s para la respuesta vía `.timeout`;
  al vencer, `request.abort()`. **Siempre** drenar el body, incluso en no-200
  (`response.drain()`), para no fugar sockets.
- Resultado → `ValueNotifier<LinkStatus>`. Notificar en cada poll (el `Online` cambia
  siempre por `receivedAt`); la deduplicación vive en el consumidor (tray).

### Ficheros

```
lib/
  main.dart            arranque + wiring (window, tray, poller, alert)      ~90 líneas
  link_status.dart     modelo sealed + parseo + formatos + FleetState       ~150
  poller.dart          bucle HTTP → ValueNotifier<LinkStatus>               ~60
  idle_alert.dart      máquina de estados de la alerta (pura)               ~40
  tray.dart            LinkStatus → icono/tooltip/menú (dedupe) + eventos   ~110
  status_window.dart   widget de la tabla                                   ~150
tool/
  gen_icons.dart       genera assets/tray/*.png y *.ico                     ~60
assets/tray/           offline|idle|busy|compacting .png + .ico (commiteados)
test/
  link_status_test.dart
  idle_alert_test.dart
windows/runner/main.cpp            mutex de instancia única
windows/runner/flutter_window.cpp  quitar Show() automático
macos/Runner/Info.plist            LSUIElement
macos/Runner/AppDelegate.swift     no terminar al cerrar última ventana
```

---

## Gate (aplicar tras cada tarea, ejecutado por el implementador)

```
flutter analyze
flutter test
flutter build windows --debug
```

Los tres deben salir en verde. `flutter build windows --debug` es obligatorio aunque la
tarea sea solo Dart: es la única forma de detectar roturas del runner o de plugins.
Además, cada tarea lista su verificación manual en **Verify**; el implementador la
ejecuta cuando es posible en esta máquina (Windows) y reporta el resultado literal.

---

## Tareas

### T0 — Commit baseline del scaffold (committer, no implementador)

- **Where:** todo el repo. Estado actual: `## No commits yet on master`, todo untracked.
- **Problem:** sin baseline, `git diff` de la T1 incluiría el scaffold entero y la review
  no sería por tarea.
- **Fix:** `git add -A && git commit -m "chore: flutter desktop scaffold"`. Verificar antes
  que `.gitignore` excluye `build/`, `.dart_tool/`, `.idea/`, `*.iml` (los excluye; `.vscode/`
  entra, es intencional). **No** añadir `PLAN.md` ni `LEDGER-*.md` a este commit — quedan
  untracked durante el run y se commitean al final o se borran (ledger).
- **Risk:** none.
- **Verify:** `git status --short` solo muestra `?? PLAN.md` (y el ledger cuando exista).

### T1 — Dependencias, generador de iconos y assets

- **Where:** `pubspec.yaml`; nuevo `tool/gen_icons.dart`; nuevo dir `assets/tray/`.
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
- **Risk:** low.
- **Verify:** `ls assets/tray` muestra 8 ficheros; abrir un `.ico` con el visor de Windows
  y confirmar que tiene múltiples tamaños y transparencia (o `python -c "from PIL import Image; print(Image.open('assets/tray/idle.ico').info)"` si PIL está disponible; si no, inspección visual). Gate verde.

### T2 — Modelo `LinkStatus` + parseo + formatos + `FleetState` (puro, con tests)

- **Where:** nuevo `lib/link_status.dart`; nuevo `test/link_status_test.dart`.
- **Problem:** no existe el modelo. Es el corazón testeable de la app.
- **Fix:** en `link_status.dart`, sin imports de Flutter (solo `dart:core`):
  ```dart
  sealed class LinkStatus { const LinkStatus(); }
  final class NoHub extends LinkStatus { const NoHub(); }
  final class Unsupported extends LinkStatus { const Unsupported(); }
  final class Online extends LinkStatus {
    final String hub; final List<Terminal> terminals; final DateTime receivedAt;
    /// Lanza FormatException si el payload no cumple el contrato (→ el caller mapea a Unsupported).
    factory Online.fromJson(Map<String, dynamic> json, DateTime receivedAt);
    FleetState get fleet;
  }
  final class Terminal {
    final String name, role; final String? status; final int? sinceSeconds;
    final String? cwd; final ContextUsage? context;   // null == payload "context": null
    bool get isIdle => status == 'idle';
    bool get isCompacting => status == 'compacting';
    /// Etiqueta sin edad: "idle" | "tool:bash" | "?"
    String get statusLabel;
    /// Edad actual en segundos, o null si status desconocido.
    int? ageSeconds(DateTime receivedAt, DateTime now);
  }
  final class ContextUsage { final int? tokens; final int window; String get label; } // "92K/272K (34%)" | "?/272K"
  enum FleetState { offline, idle, busy, compacting }
  String formatTokens(int n);        // 92K / 1.3M
  String formatDuration(int seconds); // 12s / 7m / 2h
  String shortenHome(String path, String? home); // C:/Users/andre/x → ~/x ; también acepta backslashes
  ```
  Validación en `fromJson` = misma que `isStatusPayload` en `pi-link.mjs`: `hub` string,
  `port` number, `terminals` lista no vacía de mapas, cada uno con `name` string y `role`
  string; `status` y `sinceSeconds` ambos presentes o ambos ausentes (si uno solo → inválido);
  `context` es `null` o mapa con `window` int y `tokens` int|null; `cwd` string opcional.
  Campos extra se ignoran. `FleetState` según §Diseño (orden: offline → compacting → busy → idle).
- **Tests obligatorios** (`test/link_status_test.dart`), usando los payloads del README:
  - Payload completo de 3 terminales → parsea; `fleet == busy` (uno en `tool:*`, otro desconocido).
  - `context: null` → `ContextUsage == null`, label `?`.
  - `tokens: null` → `?/272K`.
  - Sin `status` → `statusLabel == '?'`, `ageSeconds == null`, fleet no es `idle`.
  - Status desconocido `"dreaming"` → label `dreaming`, fleet `busy`.
  - Todos `idle` → `fleet == idle`; uno `compacting` + otro `thinking` → `compacting`.
  - `status` presente sin `sinceSeconds` → `FormatException`. `terminals: []` → `FormatException`.
    `hub` no string → `FormatException`.
  - `formatTokens`: 92000→`92K`, 272000→`272K`, 1300000→`1.3M`, 2000000→`2.0M`, 999→`999`.
  - `formatDuration`: 12→`12s`, 420→`7m`, 7200→`2h`.
  - `ageSeconds`: `sinceSeconds 10`, recibido hace 5 s → 15.
  - `shortenHome('C:/Users/andre/my-project', 'C:\\Users\\andre')` → `~/my-project`.
- **Risk:** low.
- **Verify:** gate verde; `flutter test` reporta todos los tests de arriba.

### T3 — `Poller`

- **Where:** nuevo `lib/poller.dart`.
- **Problem:** hay que consultar `/status` según §Diseño/Polling.
- **Fix:**
  ```dart
  class Poller {
    Poller({this.interval = const Duration(seconds: 2)});
    final Duration interval;
    final status = ValueNotifier<LinkStatus>(const NoHub());
    final _client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    bool _stopped = false;
    Future<void> run() async { while (!_stopped) { status.value = await _poll(); await Future<void>.delayed(interval); } }
    void dispose() { _stopped = true; _client.close(force: true); status.dispose(); }
    Future<LinkStatus> _poll() async { ... }
  }
  ```
  `_poll`: `getUrl(Uri.http('127.0.0.1:9900', '/status'))` → `close()` con `.timeout(2 s)`;
  en timeout → `request.abort()` y devolver `NoHub`. `SocketException`/`HttpException`/`TimeoutException`
  → `NoHub`. Status ≠ 200 → `await response.drain()` → `Unsupported`. 200 → leer body
  (`utf8.decoder.bind(response).join()`), `jsonDecode`; si no es `Map` o `Online.fromJson` lanza
  `FormatException` → `Unsupported`. `receivedAt = DateTime.now()` justo tras recibir la respuesta.
  Puerto fijo 9900 (la extensión pi-link también lo tiene hardcodeado); una constante, no config.
  `ValueNotifier` viene de `package:flutter/foundation.dart` (único import de Flutter).
- **Risk:** medium — semántica de red; los errores aquí son silenciosos.
- **Verify:** gate verde. Manual (implementador, en Windows):
  1. Sin hub: un `dart` script o `flutter run` temporal que imprima `status.value` → `NoHub` cada 2 s sin crecer handles (comprobar en Task Manager que el proceso no acumula sockets tras 1 minuto).
  2. Con `python -m http.server 9900` (responde 200 con HTML) → `Unsupported`.
  3. Con un terminal Pi en `--link` → `Online` con la lista correcta.
  Reportar los tres resultados literalmente. No hay test unitario obligatorio para
  esta clase (requiere red); si el implementador quiere uno con `HttpServer` local en
  puerto efímero, el puerto debe ser inyectable **solo** vía constructor con default 9900 —
  no añadir config de usuario.

### T4 — `IdleAlert` (máquina de estados pura, con tests)

- **Where:** nuevo `lib/idle_alert.dart`; nuevo `test/idle_alert_test.dart`.
- **Problem:** implementar la regla de disparo de §Diseño/Alerta de forma testeable y sin UI.
- **Fix:**
  ```dart
  /// Dispara cuando el fleet pasa de trabajar a estar todo idle durante [confirmations] muestras seguidas.
  class IdleAlert {
    IdleAlert({this.confirmations = 2});
    final int confirmations;
    bool muted = false;
    DateTime? lastAllIdle;   // última vez que se observó idle confirmado (haya sonado o no)
    bool _armed = false; int _idleStreak = 0;
    /// Devuelve true si hay que mostrar la alerta ahora.
    bool onSample(FleetState state, DateTime now) { ... }
  }
  ```
  Semántica: `busy`/`compacting` → `_armed = true`, `_idleStreak = 0`, devuelve false.
  `offline` → `_armed = false`, `_idleStreak = 0`, false. `idle` → `_idleStreak++`; si
  `_idleStreak == confirmations`: `lastAllIdle = now`; si `_armed` → `_armed = false` y devuelve
  `!muted`; si no armado → false. Con `_idleStreak > confirmations` → false (no repetir).
- **Tests obligatorios:**
  - `busy, idle, idle` → `[false, false, true]`.
  - `busy, idle, busy, idle, idle` → último `true`, los demás `false`.
  - `idle, idle, idle` (arranque ya idle, nunca armado) → todo `false`, pero `lastAllIdle` se fija en la 2ª.
  - `busy, offline, idle, idle` → todo `false` (offline desarma).
  - `busy, idle, idle` con `muted = true` → todo `false`, `lastAllIdle` fijado.
  - `busy, idle, idle, idle, idle` → solo un `true`.
  - `confirmations: 1`: `busy, idle` → `true` en la 2ª.
- **Risk:** low.
- **Verify:** gate verde.

### T5 — Tray, ventana de estado y `main.dart` (wiring con plugins)

- **Where:** nuevos `lib/tray.dart`, `lib/status_window.dart`; reescribir `lib/main.dart`.
- **Problem:** unir T2–T4 con `tray_manager` y `window_manager` según §Diseño.
- **Fix:** Antes de escribir, **lee la API instalada** en
  `%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\tray_manager-0.5.3\lib\` y
  `window_manager-0.5.2\lib\` (nombres exactos de `TrayListener`, `Menu`/`MenuItem`,
  `getBounds`, `WindowOptions`, `waitUntilReadyToShow`, `setPreventClose`, `WindowListener`).
  El plan pinta invariantes, no firmas.

  **`tray.dart`** — `class Tray with TrayListener`:
  - `Future<void> init()`: `trayManager.addListener(this)`; aplica `sync` inicial con `NoHub`.
  - `Future<void> sync(LinkStatus s, {required bool muted})`: calcula `(iconPath, tooltip, menuKey)`;
    llama a `setIcon`/`setToolTip`/`setContextMenu` **solo** para lo que cambió respecto a lo último
    aplicado (guardar los tres últimos valores como campos). `iconPath` =
    `assets/tray/<fleet>.${Platform.isWindows ? 'ico' : 'png'}`. Menú según §Diseño/Tray;
    el checkbox de silencio refleja `muted`; la etiqueta Mostrar/Ocultar refleja `windowVisible`.
    Ambos son parámetros de `sync` y forman parte de `menuKey` (su cambio regenera el menú).
  - Callbacks: `onTrayIconMouseDown` → `onToggleWindow()`; `onTrayIconRightMouseDown` →
    `trayManager.popUpContextMenu()`; `onTrayMenuItemClick(item)` por `key`:
    `'show'` → `onToggleWindow()`, `'mute'` → `onToggleMute()`, `'quit'` → `onQuit()`.
    Las tres son callbacks `VoidCallback` inyectadas por constructor — el tray no conoce
    `windowManager` ni el poller.
  - Tooltip ≤ 127 chars: si el nombre del hub no cabe, no lo incluyas; el resumen numérico basta.

  **`status_window.dart`** — `class StatusView extends StatefulWidget` que recibe
  `ValueListenable<LinkStatus> status`, `ValueListenable<DateTime?> lastAllIdle` y
  `VoidCallback onTap`. `Timer.periodic(1 s)` en `initState` → `setState` para las edades;
  cancelar en `dispose`. Raíz: `GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap)`
  — un click en cualquier punto oculta la ventana. Layout: `Material` + `Column` + filas con
  `Row`/`Text` monoespaciado (`FontFeature.tabularFigures` o `fontFamily: 'Consolas'`/fallback);
  ≤ 10 filas, sin scroll ni builders. Tema oscuro simple (`ThemeData.dark()`), sin assets de fuentes.
  Sin `MouseRegion`, sin timers de auto-hide.

  **`main.dart`**:
  ```
  main():
    WidgetsFlutterBinding.ensureInitialized(); await windowManager.ensureInitialized();
    const opts = WindowOptions(size: Size(420, 320), skipTaskbar: true, alwaysOnTop: true,
                               titleBarStyle: TitleBarStyle.hidden, windowButtonVisibility: false);
    await windowManager.waitUntilReadyToShow(opts, () async { await windowManager.setPreventClose(true); }); // sin show()
    runApp(App());
  ```
  `App` (StatefulWidget con `WindowListener`) es dueño de: `Poller`, `IdleAlert`, `Tray`,
  `ValueNotifier<DateTime?> lastAllIdle`, `bool _visible` (espejo local de la visibilidad,
  para no consultar `isVisible()` async en cada `sync`).
  - `initState`: `poller.status.addListener(_onStatus)`; `poller.run()` (no await);
    `tray.init()`; `windowManager.addListener(this)`.
  - `_onStatus`: `fleet = status is Online ? status.fleet : FleetState.offline`;
    `fire = alert.onSample(fleet, now)`; `lastAllIdle.value = alert.lastAllIdle`;
    `tray.sync(status, muted: alert.muted, windowVisible: _visible)`; si `fire && !_visible` → `_show()`.
  - `_show()`: posiciona según §Diseño/Ventana (usar `trayManager.getBounds()`; `null` → `center()`),
    `windowManager.show()`, `_visible = true`, re-`sync` del tray (etiqueta Mostrar/Ocultar).
  - `_hide()`: `windowManager.hide()`, `_visible = false`, re-`sync` del tray.
  - `onWindowClose` → `_hide()` (con `preventClose` activo no cierra). **No** escuchar `onWindowBlur`.
  - Toggle (tray click izquierdo, item Mostrar/Ocultar): `_visible ? _hide() : _show()`.
  - `StatusView.onTap` → `_hide()`.
  - Quit: `poller.dispose(); await trayManager.destroy(); await windowManager.destroy();` y `exit(0)` si `destroy` no termina el proceso.
  - Sin `Provider`, sin `InheritedWidget` propio: `StatusView` recibe los `ValueListenable` por constructor.
- **Invariantes a verificar contra el código de los plugins (no las asumas):**
  1. `waitUntilReadyToShow` sin llamar a `show()` deja la ventana oculta en Windows una vez
     aplicado T6. Si el plugin necesita `hide()` explícito en el callback, añadirlo y anotarlo.
  2. `setPreventClose(true)` hace que `onWindowClose` se dispare y la ventana **no** se destruya.
  3. `getBounds()` del tray devuelve coordenadas en la misma unidad que `setPosition` de
     `window_manager` (lógicas vs físicas). Si difieren, convertir con
     `WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio` y **declarar la desviación**.
  4. `onTrayIconMouseDown` se dispara con click izquierdo en Windows sin `popUpContextMenu`.
- **Risk:** medium — es la tarea más grande y wirea dos plugins. El implementador entra con ventana compactada.
- **Verify:** gate verde. Manual en Windows (`flutter run -d windows`):
  1. Al arrancar: aparece icono gris en el tray, **ninguna ventana** (con T6 aplicado; sin T6 puede haber flash — anotar).
  2. Arrancar `pi --link` en un terminal → icono verde en ≤ 4 s; tooltip `pi-link · 1 online · todos idle`.
  3. Click izquierdo en el icono → ventana junto al tray con la fila del terminal y edad subiendo cada segundo. Click en otra aplicación → **sigue visible**. Click dentro de la ventana → se oculta. Click en el icono → aparece; click en el icono otra vez → se oculta.
  4. Click derecho → menú con la fila, Mostrar (u Ocultar si está visible), Silenciar, Salir.
  5. Con la ventana oculta, pedir al terminal Pi algo que tarde >5 s → icono azul; al terminar, tras ~4 s la ventana aparece sola, `Última vez todos idle` muestra la hora, y **permanece** hasta que la clickeas.
  6. Silenciar → repetir 5: icono cambia, ventana no aparece, `Última vez todos idle` se actualiza.
  7. Salir → el proceso termina (comprobar en Task Manager).
  Reportar literalmente qué pasó en cada paso.

### T6 — Runner Windows: instancia única + arranque oculto (**sensible, serializada**)

- **Where:** `windows/runner/main.cpp` (`wWinMain`, tras `CoInitializeEx`, ~línea 18);
  `windows/runner/flutter_window.cpp` (`FlutterWindow::OnCreate`, callback `SetNextFrameCallback`, ~línea 31).
- **Problem:** (a) dos copias del tray app = dos iconos; (b) el runner llama `this->Show()` al primer
  frame → flash de la ventana antes de que Dart pueda ocultarla.
- **Fix:**
  (a) En `main.cpp`, antes de crear la ventana:
  ```cpp
  // Single instance: a second launch exits silently. The mutex is released by the OS on process exit.
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, L"pi_link_status.single_instance");
  if (mutex == nullptr || ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }
  ```
  No cerrar el handle hasta el final (`::CloseHandle(mutex)` antes de `return EXIT_SUCCESS` final; opcional). No activar la instancia existente (fuera de alcance v1).
  (b) En `flutter_window.cpp`, dentro de `OnCreate`, eliminar la línea `this->Show();` del
  `SetNextFrameCallback` (dejar el callback vacío o eliminarlo si queda vacío y el compilador lo permite).
  Esta es la receta oficial de `window_manager` para "hidden at launch"; confirmar en su README
  (`%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\window_manager-0.5.2\README.md`) y seguir **exactamente**
  lo que pida esa versión si difiere de lo anterior.
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
| 0 | T0 baseline commit | none | committer; sin implementador |
| 1 | T1 deps + iconos | low | |
| 2 | T2 modelo + tests | low | puro; el reviewer debe comprobar cada regla del contrato |
| 3 | T4 IdleAlert + tests | low | puro; antes que T3 porque T5 necesita ambos y T3 es el más lento de verificar manualmente |
| 4 | T3 Poller | medium | verificación manual de red |
| 5 | T5 tray + ventana + main | medium | **compactar implementador antes**; la tarea más grande |
| 6 | T6 runner Windows | medium/high | **sensible, serializada**; compactar antes; desacuerdos → usuario |
| 7 | T7 macOS | low | declarativo |

Alternativa aceptable: T6 antes de T5 (para que la verificación manual de T5 ya sea zero-flash).
El orquestador decide según el estado de ventana del implementador; ambas órdenes son válidas.
No hay dos tareas que toquen el mismo fichero excepto `pubspec.yaml` (solo T1) y `main.dart` (solo T5).

Gate tras cada tarea: `flutter analyze && flutter test && flutter build windows --debug`.

Commit por tarea, mensajes en inglés, imperativo, prefijo convencional:
`chore: flutter desktop scaffold` · `build: add tray/window deps and tray icons` ·
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
- `launch_at_startup`. Se añade después si el usuario lo pide.
- Activar la instancia existente al lanzar una segunda (`windows_single_instance`). El mutex basta.
- Migrar a `nativeapi-flutter` (anunciado por leanflutter): inmaduro; no en v1.
- Linux: no hay `getBounds` ni tooltip en AppIndicator; el click izquierdo puede abrir el menú. Se
  acepta la degradación ("Mostrar" en el menú, ventana centrada). No intentar workarounds.
- Iconos `isTemplate` en macOS: descartado, el color es la señal.
- Info-only: Flutter 3.47.2 trae Dart 3.13.2 (no 3.12); `pubspec.yaml` ya tiene `sdk: ^3.12.2`, compatible. No tocar.
