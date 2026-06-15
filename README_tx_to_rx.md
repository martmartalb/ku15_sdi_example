# Test TX-to-RX — Loopback físico J2 → J3

Banco de pruebas que valida la cadena SDI de extremo a extremo haciendo que la
propia FPGA genere una señal, la saque por J2, vuelva por un cable BNC a J3, y
la decodifique internamente. Parte del proyecto de passthrough 3G-SDI Level A en
`xcku15p-ffve1517-2-i` (ALINX AXKU15 + FMC FH1219).

---

## 1. Propósito

Cerrar el lazo con el propio hardware como juez: comprobar que la trama SDI que
genera la FPGA es válida recorriendo el **camino físico real** (driver U3, cable,
equalizer U8, ambos canales del GT), sin depender del MD-LX.

```
generador -> core SDI TX -> GTH X0Y13 -> U3 -> J2
   -> [cable BNC] ->
J3 -> U8 -> GTH X0Y14 -> core SDI RX -> decodifica -> ILA
```

A diferencia del self-check interno del TX-only (que miraba sdi_tx_data antes del
GT), aquí la señal atraviesa los conectores y los chips GS12190 físicos.

---

## 2. Arquitectura

| Archivo                      | Rol                                                          |
|------------------------------|--------------------------------------------------------------|
| `sdi_3g_a_top_tx_to_rx.v`    | Top. Infraestructura de reloj (puente 148.5), LEDs, GS12190. |
| `sdi_3g_a_tx_pattern.v`      | Generador + core SDI TX + core SDI RX decodificador + ILA.   |
| `constraints_tx_to_rx.xdc`   | Pines: TX (X0Y13/J2), RX (X0Y14/J3), U3, U8.                 |

- Reusa el Wizard `gtwizard_ultrascale_0` (TX+RX) con **pines RX reales**
  conectados a J3 (`gth_rxp_bus = {gth_rx_p, 1'b0}`).

### Mapeo de canales GT (IMPORTANTE)

- **TX = GTHE4_CHANNEL_X0Y13** (-> U3 -> J2).
- **RX = GTHE4_CHANNEL_X0Y14** (<- U8 <- J3).  Config actual (se probó X0Y12/U13/J4 y se volvió a esta).
- Ambos canales están en el **Quad X0Y3** (canales X0Y12..X0Y15), así que
  siguen compartiendo QPLL0 y el refclk; el puente de reloj 148.5 no cambia.
- CUIDADO con el vector `gtwiz_userdata`: el rango de bits de cada canal NO
  depende del número absoluto del canal (X0Y12/X0Y13/...) sino del orden lógico
  de configuración en el GT Wizard. Solo hay 2 canales habilitados, compactados
  en un vector de 40 bits: RX en `[39:20]`, TX en `[19:0]`. Al cambiar el RX de
  X0Y12 a X0Y14 SOLO se toca el LOC físico (XDC), no el orden lógico del Wizard,
  por lo que el mapeo del vector se mantiene. VERIFICADO en ILA: el RX sigue
  recuperando 0x2D0/0x200 correctamente con `sdi_rx_datain = gtwiz_userdata_rx[39:20]`.
- **Dos instancias del core SDI v3.0**: una genera (sección TX), otra decodifica
  lo que vuelve por J3 (`u_sdi_rx`, en dominio `rx_clk_int`, reset `sdi_rx_rst`).
- Sin FIFO ni reenvío: solo generar, decodificar y observar en el ILA.

### Dominios de reloj

- TX vive en `tx_clk_int` (QPLL local).
- RX vive en `rx_clk_int` (recuperado por el CDR de la señal que vuelve por J3).
- En este loopback el RX recupera el reloj de NUESTRA propia señal TX, por lo
  que `rx_clk_int` y `tx_clk_int` son la misma frecuencia (auto-genlock).
  Por eso este test valida la TRAMA, **no** el drift del passthrough real.

### Generador

- Raster 1080p60 3G-A: 1125 líneas × 2200 muestras, contadores `px`/`line`.
- Patrón: color plano (gris, FLAT_Y=0x2D0 / FLAT_C=0x200).
- **Inyecta los TRS (EAV/SAV) en el flujo de vídeo de entrada** (`tx_video_a_y_in`
  / `tx_video_a_c_in`). Esto es lo que el core necesita para formar la trama
  (ver sección 7). Estructura por línea (px 0..2199):
  - px 0..3   : EAV (`3FF 000 000 XYZ_eav`)
  - px 4..275 : blanking horizontal (aquí el core inserta LN/CRC/VPID)
  - px 276..279 : SAV (`3FF 000 000 XYZ_sav`)
  - px 280..2199 : vídeo activo
- Con los TRS presentes, el core **sí** inserta CRC, line number y VPID
  (`0x89 CB 80 01`), demostrado en hardware (ver sección 10).
- **Geometría vertical (Nivel 2):** vídeo activo en líneas 42..1121 (V=0), resto
  blanking vertical (V=1). El EAV anticipa el V de la línea siguiente; el SAV
  lleva el de la actual. Con esto el MD-LX YA MUESTRA la imagen (ver sección 11).
- **Patrón seleccionable** (`localparam PATTERN_MODE`): 0 = gris, 1 = rojo.
  Croma 4:2:2 alternando Cb/Cr según `px[0]`. Ambos validados en el MD-LX.

---

## 3. Mapa de LEDs (active-LOW)

| LED                  | Señal                  | Significado                       |
|----------------------|------------------------|-----------------------------------|
| `led_qpll0_lock`     | `gth_qpll0_lock`       | QPLL lockeado                     |
| `led_tx_ready`       | `gt_tx_done & tx_active`| TX del GT operativo              |
| `led_rx_locked`      | `tx_selfcheck_locked`  | RX engancha la trama del loopback |

---

## 4. ILA (clk = rx_clk_int, 24 probes)

Versión actual del ILA, con las salidas del core TX, el contador de línea y el
line number decodificado por el RX (`rx_a_line`).

| Probe | Señal               | Ancho | Para qué                              |
|-------|---------------------|-------|---------------------------------------|
| 0     | gth_qpll0_lock      | 1     | QPLL lock                             |
| 1     | tx_ready            | 1     | TX operativo                          |
| 2     | gt_tx_done          | 1     |                                       |
| 3     | tx_active           | 1     |                                       |
| 4     | tx_selfcheck_locked | 1     | RX engancha?                          |
| 5     | gt_rx_done          | 1     |                                       |
| 6     | rx_active           | 1     |                                       |
| 7     | rx_crc_err_a        | 1     | errores de CRC?                       |
| 8     | rx_a_vpid_valid     | 1     | VPID validado por el RX?              |
| 9     | gs12190_u8_lock     | 1     | equalizer (U8) engancha?              |
| 10    | gs12190_u8_los      | 1     | pérdida de señal en J3?               |
| 11    | rx_ds1a_out         | 10    | Y recuperado por el RX (XYZ en TRS)   |
| 12    | rx_ds2a_out         | 10    | C recuperado por el RX                |
| 13    | rx_a_line           | 11    | line number decodificado por el RX    |
| 14    | rx_eav              | 1     | EAV detectado por el RX               |
| 15    | rx_sav              | 1     | SAV detectado por el RX               |
| 16    | rx_trs              | 1     | TRS detectado por el RX               |
| 17    | rx_a_vpid           | 32    | VPID recuperado                       |
| 18    | sdi_rx_datain       | 20    | palabra cruda RX del GT               |
| 19    | tx_video_y          | 10    | ENTRADA Y al core (con TRS)           |
| 20    | tx_video_c          | 10    | ENTRADA C al core (con TRS)           |
| 21    | tx_ds1a_out         | 10    | SALIDA DS1 del core                   |
| 22    | tx_ds2a_out         | 10    | SALIDA DS2 del core                   |
| 23    | line                | 11    | número de línea (TX)                  |

Nota: probes 19-23 están en el dominio `tx_clk_int`; en el loopback es la misma
frecuencia que `rx_clk_int` (auto-genlock), pero formalmente es cruce de dominio.

---

## 5. Montaje físico

- **Cable BNC entre J2 y J3** (imprescindible; sin él el RX no recibe nada).
- XDC del passthrough completo (TX X0Y13, RX X0Y14, U3 driver, U8 equalizer).
  No el `constraints_txonly`.
- `ila_0` configurado con los anchos de la tabla anterior (24 probes).

---

## 6. Resultados obtenidos

### Lo que funciona (validado)

- `gth_qpll0_lock`, `tx_ready`, `gt_tx_done`, `tx_active` = 1. ✓
- `tx_selfcheck_locked` = 1: el RX engancha la trama que vuelve por J3. ✓
- `gt_rx_done`, `rx_active` = 1; `gs12190_u8_lock` = 1, `gs12190_u8_los` = 0:
  el equalizer U8 recibe la señal del cable correctamente. ✓
- `rx_crc_err_a` = 0 siempre (trigger en ==1 nunca dispara): cero errores de CRC.
- En programaciones con buen alineamiento, `rx_ds1a_out` = `tx_video_y` y
  `rx_ds2a_out` = `tx_video_c` exactos (p. ej. 0x2D0 / 0x200): el vídeo se
  recupera idéntico tras el viaje físico completo. ✓

### Validación del RX con señal real (BlackMagic)

Como referencia y validación independiente, se inyectó en el RX (J3) una señal
SDI real procedente de una BlackMagic (en lugar del loopback propio). Con esa
señal, la cadena RX funcionó de forma COMPLETA y CORRECTA:

- **Colores recuperados correctamente:** al enviar distintos colores desde la
  BlackMagic (p. ej. rojo), `rx_ds1a_out`/`rx_ds2a_out` mostraban los valores
  Y/C correctos del color, y la estructura de la línea se leía bien.
- **TRS detectado:** `rx_trs`, `rx_eav` y `rx_sav` SÍ se ponían a alto en los
  instantes correctos (el `rx_eav` coincidía con la palabra XYZ del EAV = 0x274).
- **VPID válido:** `rx_a_vpid_valid` = 1 de forma sostenida, con
  `rx_a_vpid = 0x0180CB89` (= bytes 0x89 CB 80 01: 3G-A Level A, 60 Hz). Es el
  VPID real que emite la BlackMagic y que el MD-LX acepta.
- **Estructura de línea legible:** tras el EAV (0x274) se identificaban las dos
  palabras de Line Number (iguales en Y y C) y las dos de CRC (distintas en Y y
  C), seguidas del blanking / HANC.

CONCLUSIÓN de esta prueba: **la cadena de RECEPCIÓN (J3 -> U8 -> GTH X0Y14 ->
core SDI RX) está completamente validada.** Detecta TRS, recupera vídeo, lee
line number/CRC y extrae el VPID. Por tanto, los problemas observados con la
señal PROPIA (rx_eav/sav/trs a 0, VPID no válido) NO son del receptor, sino de
que la señal GENERADA no contiene TRS (ver secciones 6, 7). El RX es un juez
fiable: con señal buena funciona, con la generada (sin TRS) no detecta nada.

### Problema 1 (RESUELTO): el VPID no se insertaba sin TRS en la entrada

Diagnóstico inicial (con el generador que daba vídeo plano SIN TRS):
- `rx_a_vpid_valid` nunca subía a 1 y `rx_a_vpid` siempre 0x00000000.
- `tx_ds1a_out` era SIEMPRE igual a `tx_video_y` (0x2D0), en todas las líneas.
- `rx_eav`, `rx_sav`, `rx_trs` SIEMPRE a 0 con la señal propia, mientras que con
  una señal real (BlackMagic) SÍ se activan.

Causa raíz (sección 7): el core espera los TRS EN LA ENTRADA. Al inyectarlos
(sección 10), el problema queda RESUELTO: el core forma la trama e inserta el
VPID. El alineamiento del RX (Problema 1) sigue siendo un punto aparte, pero no
impide la validación del VPID cuando hay buen alineamiento.

---

## 7. CONCLUSIÓN — Causa raíz: el core NO genera los TRS

La documentación oficial (PG071 y app notes asociadas) lo confirma:

> "The SDI core does no mapping between native video formats and elementary data
>  streams. The user application must do any necessary mapping of video to
>  elementary data streams prior to providing those streams to the SDI
>  transmitter."

**El core SDI v3.0 NO genera los EAV/SAV (TRS). Espera que el flujo de vídeo de
entrada (`tx_video_a_y_in`/`tx_video_a_c_in`) Ya contenga la estructura completa
de la línea, incluidos los TRS (`3FF 000 000 XYZ`).** A partir de esos TRS, el
core inserta el CRC, el line number y el VPID en sus posiciones.

Por eso el core v3.0 tiene salidas `rx_eav/rx_sav/rx_trs` (las detecta en RX)
pero NO tiene una entrada `tx_trs`: espera los TRS dentro del propio stream de
vídeo del TX.

Este generador da vídeo PLANO (0x2D0 en las 2200 muestras) sin meter nunca los
TRS. Resultado:
- Sin TRS -> el core no encuentra estructura de línea -> no inserta VPID/CRC/LN.
- Sin TRS -> el RX no detecta EAV/SAV -> rx_eav/sav/trs a 0, VPID no valida.
- Sin geometría válida -> el MD-LX rechazaba la señal (no la mostraba).

(Todo esto era el estado SIN TRS. Tras inyectar los TRS y la geometría vertical,
el core forma la trama, inserta el VPID y el MD-LX muestra la imagen — ver
secciones 10 y 11.)

Esto explica TODOS los síntomas observados a lo largo del proyecto y por qué la
señal de la BlackMagic (que sí lleva TRS) funcionaba mientras la generada no.

---

## 8. El timing generator implementado

Para que el generador produzca SDI 3G-A válido se construyó un timing generator
que, en `tx_video_a_y_in`/`tx_video_a_c_in`, produce la estructura completa:
1. Vídeo activo (zona de imagen de las líneas activas).
2. EAV (`3FF 000 000 XYZ`) al final de la zona activa, con el XYZ correcto según
   F/V/H y la línea (con el EAV anticipando el V de la línea siguiente).
3. Blanking horizontal y vertical con sus valores.
4. SAV (`3FF 000 000 XYZ`) al inicio de la zona activa.
5. `tx_line_a` (el contador `line`) sincronizado con el raster.

El core, a partir de estos TRS, inserta CRC, line number y VPID. Resultado: señal
válida que la BlackMagic capta y que el MD-LX muestra en pantalla (secciones
10-11). Referencias oficiales equivalentes: XAPP1014 (mapping/timing) y XAPP1248
(control module del GT para el alineamiento RX).

---

## 9. Estado del banco y siguientes pasos

- El banco TX-to-RX cumplió y SIGUE cumpliendo su función: certificó la cadena
  física (GT, U3, cable, U8) y permitió descubrir (sección 7) y luego DEMOSTRAR
  (sección 10) que el core espera los TRS en la entrada.
- Tras inyectar los TRS y añadir la geometría vertical (Nivel 2), **el generador
  produce un 1080p60 que el MD-LX detecta y MUESTRA en pantalla** (gris o rojo).
  La BlackMagic en captura también lo capta. Objetivo del banco conseguido.
  
---

## 10. HITO DEMOSTRADO: inyectar TRS hace que el core inserte el VPID

Se modificó el generador para construir la estructura de línea con los EAV/SAV
incluidos (Nivel 1: todas las líneas activas, V=0). **Resultado en hardware:**

- `rx_trs`, `rx_eav`, `rx_sav` PASAN A ACTIVARSE (antes siempre a 0). El RX
  detecta los TRS que ahora inyecta el TX.
- Se ve la secuencia TRS en `rx_ds1a_out`/`rx_ds2a_out`: `3FF 000 000 274` (EAV).
- `rx_a_vpid_valid` = 1 y `rx_a_vpid` = el VPID insertado (`0x...CB89`). El core
  inserta el ST 352 al detectar los TRS.
- En el HANC de la línea 10 se identifica el paquete ST 352 completo:
  `000 3FF 3FF` (ADF) + DID(0x241) + SDID + DC + 4 UDW (bytes 0x89,CB,80,01 en
  los bits altos) + checksum. Tras el EAV van el Line Number (2 palabras,
  codificación SMPTE de la línea, NO el número crudo) y el CRC (2 palabras,
  distinto en Y y C).
- **Validación con receptor profesional:** conectando J2 a una BlackMagic en
  modo captura, la BlackMagic CAPTA EL GRIS correctamente. La señal generada es
  SDI 3G-A válido para un equipo profesional.

**Conclusión:** queda DEMOSTRADO  que el core v3.0 no genera los TRS
pero sí los detecta en la entrada, y a partir de ellos forma EAV/SAV/CRC/LN/VPID.
La causa raíz de la sección 7 queda confirmada con hechos.

### Codificación del TRS (verificada)

Cada TRS es `3FF, 000, 000, XYZ`. La palabra XYZ (10 bits) codifica F/V/H:
- Bit 9 = 1 (fijo); Bit 8 = F (0 en progresivo); Bit 7 = V (1 en blanking
  vertical); Bit 6 = H (1=EAV, 0=SAV); Bits 5..2 = protección
  (P3=V^H, P2=F^H, P1=F^V, P0=F^V^H); Bits 1,0 = 0.

Valores XYZ (F=0 progresivo) — CORREGIDOS y confirmados con la BlackMagic:

| Estado de línea     | SAV (H=0) | EAV (H=1) |
|---------------------|-----------|-----------|
| Vídeo activo (V=0)  | 0x200     | 0x274     |
| Blanking vert. (V=1)| 0x2AC     | 0x2D8     |

### Del Nivel 1 al Nivel 2 (MD-LX)

El Nivel 1 (todas las líneas activas) era SDI válido para la BlackMagic en
captura, pero el MD-LX (más estricto) NO lo mostraba: faltaba el blanking
vertical, sin el cual el frame no es un 1080p60 real. El Nivel 2 (sección 11)
añade esa geometría vertical y CON ÉL EL MD-LX YA MUESTRA LA IMAGEN.

---

## 11. Nivel 2: geometría vertical 1080p60 (VALIDADO EN EL MD-LX)

Se generó la geometría vertical real (SMPTE 274M):
- Líneas **42..1121**: vídeo activo (V=0) -> SAV=0x200, EAV=0x274.
- Líneas **1..41 y 1122..1125**: blanking vertical (V=1) -> SAV=0x2AC, EAV=0x2D8.

Detalle de FASE (observado en la señal real de la BlackMagic y CONFIRMADO por
experimento, ver abajo):
- El **SAV** lleva el V de la **línea actual**.
- El **EAV ANTICIPA**: lleva el V de la **línea siguiente**. P.ej. el EAV de la
  línea 1121 (última activa) ya marca V=1 porque la 1122 es blanking vertical;
  y el EAV de la línea 41 ya marca V=0 porque la 42 es activa.

En las líneas de blanking vertical el contenido de vídeo es nivel de blanking
(0x040 / 0x200), no la imagen.

### RESULTADO: el MD-LX muestra la imagen en pantalla

Con la geometría vertical correcta, **el MD-LX (Decimator) detecta la señal y
muestra la imagen en su salida HDMI a la pantalla.** El generador produce un
1080p60 que un receptor estricto acepta de principio a fin. Hito conseguido.

### Patrones de prueba

El generador tiene un selector `localparam PATTERN_MODE`:
- `0` = gris  (Y=0x2D0, Cb=Cr=0x200).
- `1` = rojo  (Y=0x110, Cb=0x066, Cr=0x340).

Ambos validados: el MD-LX muestra gris o rojo en pantalla según el modo. El croma
usa muestreo 4:2:2, alternando Cb (muestras pares) y Cr (impares) según `px[0]`.
Con el gris no se nota la alternancia (Cb=Cr); con el rojo reparte cada croma en
su muestra. Los valores del rojo son aproximados; para color "de norma" usar la
tabla SMPTE color bars.

---

## 12. Referencias

- Codificación XYZ y estructura TRS: SMPTE ST 292 / ST 425-1.
- Geometría 1080p (líneas activas 42..1121): SMPTE 274M.
- Generador/timing de referencia oficial de Xilinx: XAPP1014.
- Control module del GT (alineamiento RX en UltraScale): XAPP1248.
