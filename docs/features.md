# Qué añadir para que la gente pague

Ordenado por lo que yo haría primero. Cada ficha lleva esfuerzo estimado y, más
importante, si **se puede hacer de verdad** con lo que hay.

## Estado a día de hoy

| | Estado |
| --- | --- |
| 1. Probabilidad de victoria | ✅ Hecho |
| 2. Proyección del resultado | ✅ Hecho |
| 3. Jugadores que quedan por jugar | ✅ Hecho (por proyección pendiente, no por estado del partido) |
| 4. Aviso de cambio de liderato | ✅ Hecho |
| 5. Tarjeta para compartir | ✅ Hecho |
| 6. Puntos en el banquillo | ✅ Hecho |
| 7. Agentes libres | ✅ Hecho |
| 8. Noticias de tus jugadores | ✅ Hecho, con aviso |
| 9. Analizador de intercambios | ⬜ Pendiente |
| 10. Clasificación | ✅ Hecho (falta la probabilidad de playoffs) |
| 11. Historial de la temporada | ✅ Hecho |
| 12. Push real | ⬜ Necesita los 99 USD y servidor |
| 13. Un widget por liga | ✅ Hecho |
| 14. Apple Watch | 🟡 Live Activity en el Smart Stack, con vista propia. Falta complicación en la esfera |

Añadido fuera de la lista original: ficha de jugador, parte de lesiones con
aviso, avisos con la app cerrada, varias ligas, y traducción al inglés.

**Lo que queda de más valor**, por orden: la probabilidad de playoffs (simular
lo que resta de temporada), el analizador de intercambios, y el push cuando
tengas la cuenta de Apple.

## La observación que manda sobre todo lo demás

Tienes un motor de análisis en `app/` que la app de iPhone **no usa para nada**:
ranking propio con notas y tiers, tendencias por uso, alineación óptima, ideas
de intercambio, puntos implícitos de las casas de apuestas y emparejamiento de
noticias con jugadores. Son 3.000 líneas ya escritas y con 376 tests.

Ninguna app de marcadores de fantasy tiene eso. **Ahí está tu diferencia**, no en
enseñar puntos más bonitos. Y el trabajo no es inventarlo: es exponerlo por la
API que ya existe y pintarlo en la app.

---

## Nivel 1 — Alto impacto, poco esfuerzo

### 1. Probabilidad de victoria en vivo ⭐

"78 % de ganar" al lado del marcador, en el widget y en la Live Activity.

Es **el número más adictivo** de una app de enfrentamientos: convierte un
marcador en una historia. Sube y baja con cada jugada, y es exactamente lo que
la gente quiere mirar el domingo.

Cómo: `/projections/nfl/regular/{año}/{jornada}` da la proyección de cada
jugador. Proyección restante ≈ `max(0, proyección − puntos actuales)`. Con eso
sale el marcador final esperado de cada lado, y la probabilidad de una normal
con desviación ~26 puntos (lo típico de una jornada de fantasy).

**Esfuerzo: medio día.** Solo hace falta una llamada más, ya cacheable como el
resto.

### 2. Proyección del resultado final

"88.4 → 121.6 esperados" bajo cada equipo. Sale gratis con lo anterior.

### 3. Cuántos jugadores le quedan por jugar a cada uno

"Te quedan 3 · al rival 1". Cambia por completo la lectura del marcador: ir 10
abajo con tres por jugar es ganar, y hoy la app no lo dice.

Cómo: cruzando con el marcador de la NFL (ESPN, que tu servidor ya consulta en
`app/providers/odds.py`) se sabe qué partidos han terminado.

**Esfuerzo: medio día**, apoyándose en el servidor.

### 4. Aviso de cambio de liderato

"Te acaban de pasar" / "Vuelves a ir ganando". El detector de anotaciones ya
está: es comparar el signo de la diferencia entre dos lecturas. Emocionalmente
es el aviso más fuerte de todos.

**Esfuerzo: dos horas.**

### 5. Tarjeta para compartir el resultado

Una imagen bonita del marcador final para mandar al grupo de WhatsApp de la
liga. `ImageRenderer` de SwiftUI lo hace en 40 líneas.

No es solo una feature: **es tu canal de crecimiento**. Cada resultado
compartido lleva tu marca al grupo entero de una liga de 12 personas.

**Esfuerzo: medio día.**

---

## Nivel 2 — Lo que justifica la suscripción

### 6. Puntos que dejaste en el banquillo ⭐

"Dejaste 23,4 puntos en el banquillo". `optimal_lineup()` en
`app/league_analysis.py` ya calcula la mejor alineación posible: es restar.

Duele, y por eso se mira todas las semanas. Es de las cosas que la gente
enseña a sus amigos.

**Esfuerzo: un día** (exponerlo por la API y pintarlo).

### 7. Agentes libres recomendados ⭐

La feature clásica de las apps de pago. Tú ya tienes el ranking propio, el
filtro de "solo libres en tu liga" y las tendencias por uso. Es la pantalla que
convierte una app de marcador en una herramienta.

"Sube: Jaylen Wright — 6 acarreos más que la semana pasada, 34 % de snaps →
51 %. Libre en tu liga."

**Esfuerzo: dos días.**

### 8. Noticias de tus jugadores, con aviso

`app/matching.py` ya sabe reconocer nombres de jugador dentro de una noticia, y
`providers/news.py` agrega ESPN, CBS, Yahoo y Fox. Filtrar por tus titulares y
avisar es enchufar dos piezas que ya existen.

**Esfuerzo: un día** (más el push, ver nivel 3).

### 9. Analizador de intercambios

`find_trades()` ya propone intercambios equilibrados con las notas de ambos
equipos. En la app: "pega un intercambio y te digo si te conviene".

**Esfuerzo: dos días.**

### 10. Clasificación y camino a playoffs

Tabla de la liga y probabilidad de entrar en playoffs simulando lo que queda de
temporada (Monte Carlo, 10.000 iteraciones en el servidor, medio segundo).

**Esfuerzo: dos días.**

### 11. Historial de la temporada

Gráfica de tus puntos por jornada, racha, mejor y peor semana, y comparativa
con la media de la liga.

**Esfuerzo: un día.**

---

## Nivel 3 — Lo que hace que la app se sienta "de verdad"

### 12. Push real ⭐⭐

Avisos con el móvil bloqueado y sin abrir nada, y una Live Activity que se
actualiza sola durante todo el partido.

Es, con diferencia, **lo que más se nota**. Hoy dependemos de que iOS despierte
la app; con push es instantáneo y siempre.

Necesita: los 99 USD de Apple, una clave `.p8` de APNs y un servicio que mire
los marcadores (la Pi o un Worker). Diseño en `docs/raspberry-pi.md`.

**Esfuerzo: dos días** una vez tengas la cuenta.

### 13. Un widget por liga

Cada widget de la pantalla de inicio siguiendo una liga distinta, eligiéndola al
configurarlo. Es `AppIntentConfiguration` en vez de `StaticConfiguration`.

Es lo que la pantalla de Pro ya promete, así que conviene que exista.

**Esfuerzo: un día.**

### 14. Apple Watch

Complicación con el marcador en la esfera. Para el usuario que ya paga, esto es
lo que le hace quedarse.

**Esfuerzo: tres días.**

---

## Lo que NO se puede hacer (y por qué)

| Idea | Por qué no |
| --- | --- |
| **Cambiar alineación desde la app** | La API pública de Sleeper es de solo lectura. No hay endpoint. Lo único legítimo: un botón que abra Sleeper en tu enfrentamiento |
| Fichar o cortar jugadores | Lo mismo |
| Proponer intercambios de verdad | Lo mismo. Analizarlos sí; enviarlos no |
| Chat de la liga | Lo mismo |
| Jugada a jugada ("está en zona roja") | Haría falta play-by-play en vivo, que no es gratis en ninguna fuente seria |

Que la app sea de **solo lectura no es un defecto**, es su posicionamiento: no
compite con la app de Sleeper, la complementa. Sleeper es donde gestionas; esto
es donde miras y decides.

---

## Mi recomendación de orden

**Para lanzar (2-3 días):** 1, 2, 3, 4, 5. Todo cliente, sin depender del
servidor ni de pagar nada. Con eso la app ya es claramente mejor que mirar el
marcador en Sleeper.

**Primera actualización de pago (una semana):** 6, 7, 8. Aquí es donde el motor
de Python empieza a trabajar para ti y donde la suscripción se justifica sola.

**Cuando tengas los 99 USD:** 12 y 13. Convierten "una app que consulta" en "una
app que te avisa".

Lo demás, según lo que pida la gente. Y para eso conviene lanzar pronto con lo
del primer bloque, que es la mitad de la conversación que estás teniendo ahora
contigo mismo.
