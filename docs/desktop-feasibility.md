# T1a — Desktop feasibility: showing without stealing focus, and positioning

Investigación previa a T5. Responde tres preguntas antes de construir la UI:
mostrar la ventana sin activarla, colocarla junto al icono del tray dentro del
área útil, y qué garantiza el fallback cuando no hay datos de posición.

**Resultado corto:** el requisito de "mostrar sin robar el foco" **no lo cumple
`windowManager.show(inactive: true)`** en Windows: el parámetro `inactive` no está
implementado en el código nativo y la ventana roba el foco. **No se encontró ninguna
ruta válida de extremo a extremo dentro de las APIs públicas auditadas y de las
implementaciones instaladas.** La alternativa por opacidad (§Q1, opción B) sí evita la
activación *una vez que la ventana ya es visible*, pero **solo se verificó partiendo de
un arranque que ya la había mostrado y activado**, por lo que no constituye un camino de
producto: es incompatible con la semántica de ventana realmente oculta y con el
arranque sin destello que exigen §Diseño/Ventana y T6 (ver §Q1, "Por qué la opción B no
cierra el ciclo"). Una segunda ruta aparentemente obvia (`show()` + `blur()`) se probó y
es **peligrosa**: devuelve el foco a una ventana arbitraria, no a la que lo tenía.
**Desenlace:** el usuario resolvió la disyuntiva **relajando el requisito**, no eligiendo
un remedio técnico. v1 usa `show()`/`hide()` corriente con ventana **centrada**, acepta
que la apertura robe el foco y renuncia al anclaje junto al icono. Ver §"Decisión vigente
(v1)". Todo lo que este informe dice sobre no activación, opacidad, puente nativo y
geometría multimonitor **sigue siendo evidencia válida del contrato anterior**, pero ya
**no** son requisitos ni bloqueos de v1.

## Alcance de la evidencia

Cada afirmación de este documento lleva una de estas etiquetas:

| Etiqueta | Significado |
|---|---|
| **[OBS]** | Observado en ejecución real en esta máquina, con valores registrados |
| **[SRC]** | Leído en el código fuente/nativo instalado del plugin |
| **[SIM]** | Geometría calculada/derivada, no reproducida físicamente |
| **[NO-EXEC]** | No ejecutable en esta máquina; queda pendiente |

## Versiones probadas

| Componente | Versión |
|---|---|
| Flutter | 3.47.2 stable (revisión d3b14c8769) · Dart 3.13.2 |
| `window_manager` | 0.5.2 |
| `tray_manager` | 0.5.3 |
| `screen_retriever` | 0.2.2 (transitiva vía `window_manager`; **no importada**) |
| Windows | Windows 11, un solo monitor 2560×1600 físico, DPI 192 (escala 200 %), barra de tareas en **auto-ocultar** |

Harness temporal: proyecto Flutter aparte en `%TEMP%\pi_link_t1a_spike`, fuera del
árbol de entrega, con las mismas versiones fijadas y sin dependencias nuevas
(el acceso a Win32 usa `dart:ffi` con `kernel32!LocalAlloc`, sin `package:ffi`).
Se ejecutó como `.exe` compilado y se borró al terminar. Ningún cambio en el producto.

---

## Q1 — Mostrar una ventana `alwaysOnTop` sin activarla

### Lo que hace realmente `show(inactive: true)`

**[SRC]** `window_manager-0.5.2/lib/src/window_manager.dart:209` acepta
`show({bool inactive = false})` y envía `{'inactive': inactive}` por el method channel.
El lado nativo Windows **ignora el argumento**:

- `windows/window_manager_plugin.cpp:383` → `window_manager->Show();` (sin argumentos).
- `windows/window_manager.cpp:276-288` → `Show()` termina con
  `ShowWindowAsync(hWnd, SW_SHOW); SetForegroundWindow(GetMainWindow());`.
- `grep -rn "inactive" windows/` → **sin resultados**. El parámetro es decorativo aquí.

**[SRC]** macOS tiene el mismo problema por otra vía:
`macos/.../WindowManager.swift:134-140` → `makeKeyAndOrderFront(nil)` +
`NSApp.activate(ignoringOtherApps: true)`, siempre activa.
**[SRC]** Linux: `linux/window_manager_plugin.cc:95-99` → `gtk_widget_show()`, sin
activación explícita; el comportamiento real depende del WM. **[NO-EXEC]**

### Opción A — `show(inactive: true)` tal cual: **FALLA**

**[OBS]** spike-1, tres ciclos hide/show con el usuario en otra aplicación:

```
[Q1 cycle 2] show(inactive:true)  before: hwnd=1049812 title="pi_link_status - Visual Studio Code"
[Q1 cycle 2]                       after: hwnd=198238  title="PI_LINK_T1A_SPIKE" isFocused=true
[Q1 cycle 3] show(inactive:true)  before: hwnd=1049812 title="pi_link_status - Visual Studio Code"
[Q1 cycle 3]                       after: hwnd=198238  title="PI_LINK_T1A_SPIKE" isFocused=true
```

El foco pasó de VS Code a la ventana del harness. Requisito incumplido.

**[OBS]** Además es **no determinista**, lo que la descarta incluso como
"a veces funciona": en spike-3 el mismo `show()` robó el foco en el primer ciclo y
**no** lo robó en el segundo y el tercero, porque el bloqueo de primer plano de
Windows deniega `SetForegroundWindow` cuando el proceso ya perdió los derechos de
entrada. El comportamiento depende de si el proceso fue foreground recientemente.

### Opción C — `show(inactive: true)` + `blur()`: **PELIGROSA, descartada**

Parecía la solución barata: mostrar y devolver el foco de inmediato.
**[SRC]** `windows/window_manager.cpp:260-270` — `Blur()` recorre el Z-order con
`GetNextWindow(GW_HWNDNEXT)` y hace `SetForegroundWindow` en la **primera ventana
visible que encuentra**. No recuerda quién tenía el foco.

**[OBS]** spike-3, primer ciclo, midiendo el estado intermedio:

```
[C1] before          : hwnd=198814 title="π - fallout_newvegas_mods - nvse"
[C1] after show      : hwnd=329784 title="PI_LINK_T1A_SPIKE"      <- roba el foco
[C1] after blur      : hwnd=393258 title="<untitled hwnd 393258>" <- NO lo devuelve
[C1] after blur +500ms: hwnd=393258 title="<untitled hwnd 393258>"
```

El foco no volvió a la terminal del usuario, acabó en una ventana sin título
arbitraria. La aplicación en uso pierde el foco de forma permanente. **Descartada.**

### Opción B — nunca llamar al `Show()` nativo: no activa, pero **no cierra el ciclo**

> **Histórico.** Opción **descartada**, evaluada bajo el contrato anterior. v1 no la usa
> (§"Decisión vigente"); se conserva porque la medición es real y explica por qué no había
> salida sencilla dentro del stack declarado.

La ventana se mantiene `WS_VISIBLE` y se alterna su visibilidad efectiva con
`setOpacity()` + `setIgnoreMouseEvents()`, que no tocan el primer plano:

- **[SRC]** `SetOpacity` (`window_manager.cpp:1031-1038`) → `WS_EX_LAYERED` +
  `SetLayeredWindowAttributes(hWnd, 0, 255*opacity, LWA_ALPHA)`.
- **[SRC]** `SetIgnoreMouseEvents` (`:1058-1069`) → alterna
  `WS_EX_TRANSPARENT | WS_EX_LAYERED`. Con opacidad 0 la ventana es invisible y
  deja pasar los clics.
- Ninguna de las dos llama a `ShowWindow` ni a `SetForegroundWindow`.

**[OBS]** spike-2, tres ciclos con el usuario en Firefox:

```
[B cycle 1] before: hwnd=132156 title="Wplace ... Mozilla Firefox"
[B cycle 1]  after: hwnd=132156 title="Wplace ... Mozilla Firefox" isFocused=false IsWindowVisible=1
[B cycle 2] before: hwnd=132156 ... after: hwnd=132156 ... isFocused=false
[B cycle 3] before: hwnd=132156 ... after: hwnd=132156 ... isFocused=false
```

**[OBS] Prueba de que además se ve.** No basta con que no robe el foco: hay que
demostrar que la ventana se pinta. El harness se coloreó de magenta puro
(`0xFFFF00FF`), se posicionó en el rect físico `[200,200,1040,840]` y una captura
de pantalla externa leyó los píxeles reales del escritorio en cada fase:

| Fase | Píxel (300,300) | Píxel (600,500) | Foreground | Alt+Tab |
|---|---|---|---|---|
| `armed` (opacidad 0) | negro | negro | terminal del usuario | cumple la heurística |
| `shown` (opacidad 1) | **magenta** | **magenta** | terminal del usuario | cumple la heurística |
| `hidden` (`hide()`) | negro | negro | otra app del usuario | no cumple |

Es decir: **una vez que la ventana ya es visible**, alternar la opacidad la dibuja en
pantalla sin mover el foco de la aplicación del usuario (`isFocused=false`). Eso es lo
que se midió, y solo eso.

### Por qué la opción B **no** cierra el ciclo (incompatibilidad crítica)

La medición anterior se hizo partiendo de una ventana que **ya estaba visible y ya había
robado el foco**: el harness heredó el arranque estándar del runner. Ese detalle invalida
la opción B como camino de producto, y conviene decirlo sin rodeos.

**[SRC]** El scaffold muestra la ventana en el primer frame:
`windows/runner/flutter_window.cpp:30-32` registra
`SetNextFrameCallback([&]() { this->Show(); })`, y
`windows/runner/win32_window.cpp:152-153` implementa
`Win32Window::Show()` como `ShowWindow(window_handle_, SW_SHOWNORMAL)` — que activa.
**[OBS]** Coherente con la propia medida de spike-1: antes de cualquier `show()` desde
Dart, `[start] isVisible=true` y el primer plano ya era nuestro.

De ahí la contradicción, sin salida dentro del stack declarado:

- **Si T6 suprime ese `Show()` automático** (que es exactamente lo que T6 debe hacer para
  el arranque sin destello), el HWND nunca llega a ser visible. `setOpacity()` y
  `setIgnoreMouseEvents()` **no pueden hacer visible una ventana oculta**: solo modifican
  atributos de una ventana ya `WS_VISIBLE`. La opción B deja de funcionar.
- **Si se conserva ese `Show()` para "armar"** la opción B, el arranque vuelve a activar
  la aplicación y a robar el foco, incumpliendo el requisito (y potencialmente el
  arranque sin destello, según lo que se alcance a pintar).

Por tanto la opción B **no es una solución de extremo a extremo con las dependencias
declaradas**: requeriría, de todos modos, un show inicial nativo que no active.

Costes adicionales de ciclo de vida, aunque se resolviera lo anterior:

- `windowManager.isVisible()` seguiría devolviendo **true** mientras la ventana está
  lógicamente oculta, así que haría falta un estado lógico paralelo, y el menú del tray
  (`Mostrar`/`Ocultar`) y el tick de 1 s de edades —que §Diseño ata a la visibilidad—
  ya no podrían apoyarse en la consulta nativa.
- La ventana Flutter seguiría existiendo siempre para el compositor: transparente,
  *always-on-top* y *click-through*, en lugar de oculta.
- Es menos simple y menos eficiente que ocultar de verdad, y contradice la semántica de
  ventana realmente oculta del plan.

**El reviewer no respalda la opción B para T5.** Se documenta como evidencia de lo que sí
se midió, no como camino recomendado.

### Exposición en Alt+Tab (evidencia por heurística, no por UI)

Mientras la ventana está "armada" (`WS_VISIBLE` con opacidad 0) **cumple la heurística
estándar de elegibilidad del shell** (visible, sin owner, sin `WS_EX_TOOLWINDOW`, no
*cloaked*, con título), y deja de cumplirla tras un `hide()` real. Es decir:
**probablemente visible en Alt+Tab**. La enumeración se hizo con esa heurística
reimplementada, no inspeccionando la interfaz real de Alt+Tab, cuyas reglas son en parte
no documentadas. No debe tratarse como pertenencia observada a la UI del conmutador.

**[SRC]** La causa de la exposición: `setSkipTaskbar` usa `ITaskbarList3::DeleteTab`
(`window_manager.cpp:949-963`), que quita el botón de la barra de tareas pero **no**
pone `WS_EX_TOOLWINDOW`; el ex-style observado fue `0x80128`
(`WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_WINDOWEDGE`),
sin `WS_EX_TOOLWINDOW`. La API declarada no expone forma de añadirlo. Esto prueba la
*causa* de la elegibilidad, no la aparición efectiva en el conmutador.

### Decisión vigente (v1)

Dentro de las APIs públicas auditadas y de las implementaciones instaladas **no se
encontró ninguna ruta adecuada** para mostrar sin activar; la auditoría de fuentes
respalda con fuerza esa conclusión, aunque no puede demostrar que no exista una tercera
vía. Ante eso, el usuario prefirió **cambiar el requisito antes que añadir complejidad**:

> «No importa para esta primera versión que quite el foco. No hay problema. Aprecio las
> soluciones con menos código y menos complejidad. [...] Continua.»

**Lo que v1 hace** (§Diseño/Enmienda del plan, ya enmendado y aprobado):

- `windowManager.show()` / `hide()` corrientes, tanto en la apertura manual como en la
  alerta automática. **Se acepta que la ventana robe el foco.**
- Ventana **centrada** con el centrado que ya ofrece el plugin. Sin anclaje al icono del
  tray y sin geometría multimonitor propia.
- **Sin** puente nativo, **sin** el workaround de opacidad, **sin** dependencias nuevas.
- Se mantienen sin cambios el aviso automático y persistente de "todos idle", la ventana
  pegajosa `alwaysOnTop`, ocultar con un clic, el silencio y las reglas de miembros.
- T6 conserva únicamente instancia única y arranque realmente oculto.

**Lo que deja de ser requisito:** la no activación al mostrar y la geometría avanzada
(anclaje, área útil por monitor, DPI mixto) ya no son gates del producto v1.

### Histórico: propuesta descartada del contrato anterior

> Esta sección se conserva como evidencia del análisis previo a la enmienda.
> **No describe v1 y nada de lo que sigue está implementado ni verificado.**

Mientras el contrato exigía no activar, el reviewer propuso un puente nativo **solo para
Windows**, sin paquete nuevo ni fork: show automático con `SW_SHOWNOACTIVATE`,
`SWP_NOACTIVATE` allí donde se tocara posición o z-order, `show()` normal del plugin para
la apertura manual — que **podía** activar — y una consulta coherente del área útil del
monitor del tray si se conservaba el anclaje. El usuario aprobó inicialmente esa
propuesta y a continuación pidió ver opciones y simplificar la funcionalidad; el
desenlace fue la enmienda descrita arriba. **El puente nativo nunca se escribió ni se
probó**, así que no hay ninguna afirmación de que funcione.

Las siete pruebas que se habían definido para ese puente (arranque oculto sin destello,
ciclos oculto→show sin cambio de primer plano, ocultación real, apertura manual,
recorte contra `rcWork` con barra auto-ocultable, round-trip al 200 %, geometría pura con
orígenes negativos y áreas pequeñas) correspondían a **ese** contrato y **no son criterios
de aceptación de v1**. Las verificaciones vigentes son las de §T5 (show/hide y centrado
normales en Windows) y §T6 (arranque realmente oculto).

### Hallazgo adicional relevante para T6

**[OBS]** spike-1, antes de cualquier llamada a `show()`:
`[start] isVisible=true` y `[start] foreground ... mine=true`. El runner por defecto
muestra la ventana y roba el foco en el primer frame. **[SRC]** La cadena exacta es
`flutter_window.cpp:30-32` (`SetNextFrameCallback` → `this->Show()`) →
`win32_window.cpp:152-153` (`ShowWindow(..., SW_SHOWNORMAL)`). Confirma empíricamente la
necesidad de T6 (suprimir ese `Show()` automático).

Este hallazgo es también la razón por la que la opción B no cierra el ciclo: **el mismo
`Show()` que T6 debe eliminar es el que dejaba la ventana en el estado `WS_VISIBLE` sobre
el que se midió la opción B**. Suprimirlo y confiar en la opacidad son objetivos
mutuamente excluyentes dentro del stack declarado.

---

## Q2 — Bounds del tray, área útil, unidades y DPI

> **Sección histórica.** Se investigó bajo el contrato original, que exigía anclar la
> ventana al icono del tray. **v1 no ancla ni añade geometría propia** (§"Decisión
> vigente"), así que nada de lo que sigue es requisito ni criterio de aceptación actual.
> Las mediciones son reales y se conservan por si el anclaje se retomara más adelante.

### Unidades y origen: `tray_manager` y `window_manager` comparten el DPR de la vista

El alcance de esta sección es **el probado**: llamadas de `tray_manager` y
`window_manager` que usan el DPR actual de la vista Flutter, en una configuración de
**un solo monitor y DPI único**. No es una afirmación general sobre todo el stack: en
particular `screen_retriever` **no** comparte ese espacio (ver más abajo).

**[SRC]** Los dos plugins hacen la misma conversión y comparten espacio de coordenadas:

- `tray_manager` envía `devicePixelRatio` de la vista Flutter
  (`lib/src/tray_manager.dart:35`) y el nativo divide el rect físico por él:
  `windows/tray_manager_plugin.cpp:378-388`, sobre `Shell_NotifyIconGetRect`.
- `window_manager` hace lo mismo en `getBounds`/`setBounds`
  (`windows/window_manager.cpp:718-740`), con `window.devicePixelRatio`.

**[OBS]** Medido con DPR 2.0 (`GetDpiForWindow` = 192):

| Dato | Valor lógico (plugin) | Valor físico (Win32) |
|---|---|---|
| `windowManager.getBounds()` | `LTRB(10, 10, 430, 330)` | `GetWindowRect` = `[20, 20, 860, 660]` |
| `trayManager.getBounds()` | `LTRB(924, 799, 956, 847)` | ×DPR = `[1848, 1598, 1912, 1694]` |
| Monitor del tray | — | `rcMonitor=[0,0,2560,1600]`, `rcWork=[0,0,2560,1600]`, dpi 192 |

Conclusiones:

1. **Mismo espacio entre esas dos APIs, en DPI único.** `físico = lógico × DPR` exacto
   para la ventana, y el rect del tray usa el mismo divisor. El origen es el de la
   **pantalla virtual**, así que **puede ser negativo**; no hay que recortar a `x >= 0`.
   En DPI mixto esta coincidencia **no está verificada** — ver §"Modo de fallo".
2. **`setPosition` es fiel. [OBS]** Se pidió `Offset(536, 471)` y `getBounds()` devolvió
   `LTRB(536, 471, 956, 791)`, físico `[1072, 942, 1912, 1582]`. Round-trip exacto en la
   configuración probada (un monitor, 200 %).
3. **No multiplicar por el DPR a mano** al combinar `trayManager.getBounds()` con
   `windowManager.getBounds()`/`setPosition()`: esos valores ya vienen convertidos por el
   mismo divisor y volver a escalarlos duplicaría el error. La regla no se extiende a
   valores procedentes de `screen_retriever`, que llegan en otra escala.

### El rect del tray puede caer FUERA del monitor

**[OBS]** Hallazgo importante y contraintuitivo: el rect del tray medido fue
`[1848, 1598, 1912, 1694]` físico en un monitor de altura 1600. Se sale **94 px por
debajo del borde inferior** porque la barra de tareas está en auto-ocultar y
`Shell_NotifyIconGetRect` devuelve su posición replegada.

Consecuencia bajo el contrato original: **anclar sin recortar coloca la ventana
parcialmente fuera de pantalla**; el recorte no era una precaución teórica sino algo
necesario en esta misma máquina. **Si alguna vez se retomara el anclaje**, este es el
primer caso a cubrir. v1 no ancla, así que hoy no le aplica.

### El área útil NO está disponible en el stack declarado

**[SRC]** `tray_manager` no expone nada del monitor. `window_manager` tampoco expone
`getWorkArea`/displays: obtiene esos datos **internamente** de `screen_retriever`
(`lib/src/utils/calc_window_position.dart`), que es transitiva y que este task
prohíbe importar directamente.

**[SRC]** Lo que `screen_retriever_windows-0.2.2` haría si se declarase:
`screen_retriever_windows_plugin.cpp:119-124` divide `info.rcWork` y su origen por el
`scale_factor` **de cada monitor**. Eso es un espacio de coordenadas **distinto** del
DPR de la vista que usan `window_manager`/`tray_manager`.

#### Modo de fallo concreto en DPI mixto **[SRC]**

La mezcla no es solo "coordenadas inconsistentes": **`calcWindowPosition` puede elegir el
monitor equivocado**. Dentro del mismo cálculo conviven dos escalas distintas:

- `getAllDisplays()` devuelve `visiblePosition`/`visibleSize` divididos por el
  **DPI de cada monitor** (`screen_retriever_windows_plugin.cpp:119-124`).
- `getCursorScreenPoint()` devuelve el cursor dividido por el **DPR de la vista Flutter**
  (`screen_retriever_windows_plugin.cpp:196-203`).

`calc_window_position.dart` selecciona el display con
`Rect(...).contains(cursorScreenPoint)` comparando ambos. **El desajuste lo causa el DPI
mixto**: si todos los monitores comparten escala, ambos divisores son el mismo número y
las dos magnitudes siguen siendo coherentes. Cuando las escalas diferen, el punto y los
rectángulos quedan en unidades distintas: la comprobación puede fallar y caer en
`orElse: primaryDisplay`, o acertar el monitor pero devolver una posición mal escalada.

Un **origen virtual negativo por sí solo no produce este problema**: con escala única, las
coordenadas negativas del cursor y las de los displays se dividen por el mismo factor y
siguen siendo comparables. Lo que sí hace un origen negativo es **exponer o amplificar**
el desajuste cuando además hay escalas distintas, porque el error de escalado se aplica a
un desplazamiento grande respecto del origen. El recorte con orígenes negativos sigue
siendo, de forma independiente, **no ejecutado** aquí y debe cubrirse con tests puros de
geometría.

> **Regla — solo si se retomara el anclaje** (v1 no calcula posiciones propias): no
> mezclar aritmética de `setAlignment()` con la de
> `getBounds()`/`setPosition()`. En un solo monitor con DPI único coinciden **[OBS]**;
> en **DPI mixto** el resultado puede ser tanto un monitor equivocado como coordenadas
> mal escaladas **[SRC]**, sin verificar físicamente, y los orígenes negativos pueden
> amplificar ese caso cuando las escalas difieren.

### Experimento: derivar el área útil con `setAlignment` → `getBounds`

> **Estado: experimento en un solo display, bajo el contrato original.** No era una
> solución lista para usar entonces, y v1 ya no la necesita: no hay anclaje ni consulta
> de área útil. Se documenta porque el dato medido es real, no porque resuelva nada.

`setAlignment()` sí usa el área útil (`visiblePosition`/`visibleSize` = `rcWork`), y
`getBounds()` permite **leer el resultado**. Alineando la ventana mientras está oculta
y leyendo sus bounds se deducen los bordes del área útil, en el espacio de
`setPosition`:

- `setAlignment(Alignment.bottomRight)` ⇒ `bounds.right`/`bounds.bottom` = borde
  derecho/inferior del área útil.
- `setAlignment(Alignment.topLeft)` ⇒ `bounds.left`/`bounds.top` = borde
  izquierdo/superior.

**[OBS]** Verificado para dos alineaciones (ventana 420×320 lógicos, área útil
1280×800 lógicos):

```
setAlignment(center)      -> getBounds=LTRB(430, 240, 850, 560)  físico [860, 480, 1700, 1120]
setAlignment(bottomRight) -> getBounds=LTRB(860, 480, 1280, 800) físico [1720, 960, 2560, 1600]
```

`bottomRight` da exactamente `right=1280`, `bottom=800`, que es el área útil real
(`rcWork=[0,0,2560,1600]` ÷ 2). `topLeft` usa la misma función y devuelve
`visibleStartX/Y` directamente **[SRC]**, pero **no se ejecutó**.

**Por qué completar `topLeft` no bastaría.** Los bloqueos de esta técnica no son de
cobertura de casos, son estructurales:

- **[SRC]** Apunta al display del **cursor**, no al del **tray**. Al abrir por clic en el
  icono suelen coincidir; en una apertura automática por alerta el cursor puede estar en
  otro monitor, que es precisamente el escenario de la función. **[NO-EXEC]**
- **Muta la posición de la ventana oculta** para poder medir: convierte una consulta en
  un efecto secundario, con las carreras que eso implica frente a un `show` concurrente.
- **[SRC]** No es coherente en DPI mixto por el modo de fallo descrito arriba (mezcla del
  DPR de la vista con el `scale_factor` por monitor), y ahí no está verificada. Con DPI
  único el cálculo sí es coherente, también con orígenes negativos, pero el recorte en
  ese caso sigue sin ejecutarse.
- **[NO-EXEC]** La exclusión de la barra de tareas no se pudo observar: en esta máquina
  la barra es auto-ocultable y `rcWork == rcMonitor`. Que `setAlignment` respete
  `rcWork` es **[SRC]**, no observado.
- **[NO-EXEC]** DPI mixto y monitores con origen negativo: imposible en esta máquina
  (un solo monitor). Bajo el contrato original, la aritmética de recorte debía cubrirse
  con **tests puros de geometría** (áreas útiles de origen negativo, borde derecho, barra
  superior/inferior y área menor que el tamaño preferido). Eran criterios **históricos**:
  la enmienda de v1 los retira junto con el anclaje. En ningún caso se afirma que se
  probaran físicamente.

---

## Q3 — Fallback cuando no hay bounds (Linux) y otras limitaciones

**[SRC]** `tray_manager-0.5.3/linux/tray_manager_plugin.cc:161-167` implementa
exactamente cuatro métodos: `destroy`, `setIcon`, `setTitle`, `setContextMenu`.
**No hay** `getBounds`, **ni `setToolTip`**, ni `popUpContextMenu`. Tampoco llegan
eventos de ratón del icono, pero **por un motivo distinto** que conviene no mezclar
(ver abajo). En Linux por tanto:

- **No hay ancla posible, y la llamada no degrada en silencio: lanza.**
  **[SRC]** El handler nativo responde `fl_method_not_implemented_response_new()` a
  cualquier método fuera de esos cuatro (`linux/tray_manager_plugin.cc:161-176`), y
  `TrayManager.getBounds()` usa un `MethodChannel` corriente, no un
  `OptionalMethodChannel` (`lib/src/tray_manager.dart:205-216`), de modo que Flutter
  convierte esa respuesta en una **`MissingPluginException`**
  (`packages/flutter/lib/src/services/platform_channel.dart:351-365,539`).
  Es decir: en Linux `getBounds()` **no devuelve `null`**, **tira una excepción**.
  El camino `null` del Dart solo se activa cuando el nativo responde éxito sin datos,
  que en Windows ocurre si aún no se ha fijado el icono
  (`windows/tray_manager_plugin.cpp:373-376`).
  **Consecuencia directa para el wiring de T5:** el producto debe **evitar o proteger**
  esa llamada en Linux y **seleccionar explícitamente** el fallback centrado, en vez de
  confiar en un valor nulo que nunca llega.
- **Métodos invocables no implementados — lanzan.** `setToolTip` y `popUpContextMenu`
  están en la misma situación que `getBounds`: son llamadas Dart→nativo que caen en el
  `else` del handler, así que una invocación incondicional **lanza
  `MissingPluginException`** en vez de degradarse silenciosamente. Hay que guardarlas.
- **Eventos de ratón del icono — no lanzan: simplemente no ocurren.** Esto **no** es una
  llamada Dart que falle, sino lo contrario: son callbacks que el código nativo emite
  hacia Dart. **[SRC]** El plugin Linux solo invoca `onTrayMenuItemClick`
  (`linux/tray_manager_plugin.cc:42-50`); nunca emite `onTrayIconMouseDown` ni
  `onTrayIconRightMouseDown`, que Windows sí envía
  (`windows/tray_manager_plugin.cpp:201-205`). No hay nada que proteger con un `try`:
  los handlers de `TrayListener` existen y sencillamente no se llaman.
  **Para T5:** en Linux la interacción debe apoyarse en los ítems del menú, no en el clic
  del icono.
- **No hay tooltip.** El resumen de estado del §Diseño/Tray no existe en Linux; el
  color del icono, el menú y la ventana son la única señal. Fue una **limitación
  descubierta en T1a** y **la enmienda de v1 ya la acepta explícitamente**: el plan
  indica no invocar `setToolTip` en Linux (§Diseño/Tray) y recoge la degradación en
  §Out of scope. No queda ninguna aceptación pendiente.
- **Sin evento de clic izquierdo**: "Mostrar" en el menú es la única vía. Ya previsto.

**[OBS]** En la configuración probada (Windows, un display 1280×800 lógicos, ventana
420×320), el fallback `setAlignment` dejó la ventana íntegra dentro del área útil
(`center` y `bottomRight`, tabla de Q2). **No es una garantía general**: no está
verificado para áreas útiles menores que el tamaño preferido de la ventana, ni para DPI
mixto —donde además aplica el modo de fallo de selección de monitor descrito en Q2—, ni
para orígenes negativos, que quedan sin ejecutar aunque con escala única el cálculo sí
sea coherente. El mismo código Dart se usa en las tres plataformas **[SRC]**,
pero en Linux depende de `screen_retriever_linux`, no ejecutado aquí **[NO-EXEC]**.

**[SRC]** macOS: `tray_manager` sí implementa `getBounds`
(`macos/.../TrayManagerPlugin.swift:117`), así que el anclaje es viable; pero
`window_manager.show()` llama a `NSApp.activate(ignoringOtherApps: true)`, de modo que
el problema de foco de Q1 **también existe en macOS** y la opción B (opacidad) tendría
que revalidarse allí. **[NO-EXEC]**

### Resumen por plataforma

| Capacidad | Windows | macOS | Linux |
|---|---|---|---|
| Mostrar sin activar con `show(inactive:)` | **No** [OBS] | **No** [SRC] | Probablemente [SRC], sin verificar |
| Opacidad sin activar, **partiendo de ventana ya visible** | Sí [OBS] | Plausible, sin verificar | Plausible, sin verificar |
| Ciclo completo oculta → visible sin activar | **No** [OBS+SRC] — requiere un show inicial no activante | **No** [SRC] — `show()` fuerza `NSApp.activate` | **Sin verificar [NO-EXEC]** — `gtk_widget_show()` no activa explícitamente; depende del WM |
| `trayManager.getBounds()` | Sí [OBS] | Sí [SRC] | **No existe — lanza `MissingPluginException`** [SRC] |
| Tooltip del tray | Sí [SRC] | Sí [SRC] | **No existe — lanza** [SRC] |
| Área útil vía `setAlignment` | Solo probado en 1 display DPI único [OBS] | Sí [SRC] | Sí [SRC], sin verificar |

---

## Procedimiento (reproducible)

1. `flutter create --platforms=windows` en `%TEMP%\pi_link_t1a_spike`; fijar
   `tray_manager: 0.5.3` y `window_manager: 0.5.2` (versiones exactas, sin `^`);
   copiar `assets/tray/idle.ico` del producto.
2. `lib/main.dart`: inicializar `window_manager`, `waitUntilReadyToShow` con
   `size 420×320`, `skipTaskbar`, `alwaysOnTop`, `TitleBarStyle.hidden` y un título
   único; leer la verdad de Win32 con `dart:ffi`
   (`GetForegroundWindow`, `GetWindowTextW`, `FindWindowW`, `GetWindowRect`,
   `MonitorFromRect`, `GetMonitorInfoW`, `GetDpiForWindow`, `GetDpiForMonitor`),
   con memoria de `LocalAlloc`/`LocalFree`. Registrar todo en `spike.log`.
3. `flutter build windows --debug` y lanzar el `.exe` con `Start-Process` (no
   `flutter run`, para no acoplar el foco a la terminal que lanza).
4. Cuatro pasadas: (1) unidades + `show(inactive:)` + opacidad, (2) `show+blur` y
   prueba de opacidad con captura de pantalla, (3) estado intermedio de `show+blur`,
   (4) fases `armed`/`shown`/`hidden` con captura de píxeles y enumeración de Alt+Tab.
5. Capturas con `System.Drawing.Graphics.CopyFromScreen` tras `SetProcessDPIAware`,
   leyendo píxeles concretos dentro del rect físico de la ventana.
6. Borrar el directorio del harness.

Sin inyección de entrada en las aplicaciones del usuario: solo se **observó** qué
ventana tenía el primer plano. No se tocó el hub pi-link ni el puerto 9900.

## Qué aplica a T5 tras la enmienda

**T5 ya no está bloqueado.** Con la decisión vigente, lo que queda de este informe es
corto:

- Usar `show()`/`hide()` corrientes y el **centrado del plugin**. No hay que anclar al
  tray, ni derivar el área útil, ni escribir geometría multimonitor propia.
- **Guardar toda llamada a `trayManager.getBounds()`/`setToolTip()` en Linux**: lanzan
  `MissingPluginException`, no devuelven `null` (§Q3). Este punto **sí** sigue vigente y
  es el hallazgo de este informe con más impacto en el código de T5.
- Linux se queda sin tooltip del tray; el plan lo trata como degradación ya asumida.
- macOS y Linux siguen sin ejecutarse aquí: su comportamiento en tiempo de ejecución
  queda declarado como pendiente, no como validado.

Dejan de aplicar a v1, por la enmienda: mostrar sin activar, el puente nativo, la opción
de opacidad, el anclaje al icono y los tests de geometría para DPI mixto, orígenes
negativos y áreas menores que la ventana.
