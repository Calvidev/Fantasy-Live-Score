//  WinProbability.swift
//  "Vas ganando de 10, pero tienes un 38 % de ganar."
//
//  El método, sin misterio: a cada titular le queda por anotar su proyección
//  repartida por el reloj —medio partido por delante, media proyección—, que
//  es como lo cuenta Sleeper. Sumando sale el marcador final esperado de cada
//  lado. La incertidumbre crece con lo que queda por jugar, así que un partido
//  con todos los jugadores terminados es casi determinista y uno con cuatro
//  por jugar puede darse la vuelta.
//
//  Es una estimación, no un oráculo: no sabe de lesiones en directo ni de
//  reparto de balón. Sirve para lo que sirve.

import Foundation

struct MatchupProjection: Codable, Hashable {
    /// Marcador final esperado de cada lado.
    var mine: Double
    var theirs: Double
    /// Puntos que aún quedan por anotar, para explicar de dónde sale.
    var remainingMine: Double
    var remainingTheirs: Double
    /// De 0 a 1.
    var winProbability: Double

    var percentText: String {
        "\(Int((winProbability * 100).rounded())) %"
    }

    /// Cuántos titulares tienen todavía puntos por hacer.
    var playersLeftMine: Int
    var playersLeftTheirs: Int
}

enum WinProbability {
    /// Desviación típica por punto pendiente. Un jugador con 12 proyectados
    /// puede acabar en 4 o en 25; eso es más o menos un 60 % de dispersión.
    private static let spread = 0.6
    /// Aunque no quede nada por jugar, las correcciones de estadísticas mueven
    /// algún punto. Evita también dividir por cero.
    private static let floor = 2.0

    static func compute(for snapshot: MatchupSnapshot) -> MatchupProjection? {
        guard snapshot.opponent != nil, !snapshot.lineup.isEmpty else { return nil }

        var pendienteMio = 0.0
        var pendienteSuyo = 0.0
        var varianzaMia = 0.0
        var varianzaSuya = 0.0
        var faltanMios = 0
        var faltanSuyos = 0

        for fila in snapshot.lineup {
            if let mine = fila.mine {
                let pendiente = remaining(for: mine)
                pendienteMio += pendiente
                varianzaMia += pow(pendiente * spread, 2)
                if pendiente > 0.5 { faltanMios += 1 }
            }
            if let theirs = fila.theirs {
                let pendiente = remaining(for: theirs)
                pendienteSuyo += pendiente
                varianzaSuya += pow(pendiente * spread, 2)
                if pendiente > 0.5 { faltanSuyos += 1 }
            }
        }

        let finalMio = snapshot.me.points + pendienteMio
        let finalSuyo = snapshot.opponentPoints + pendienteSuyo

        let desviacion = max(floor, (varianzaMia + varianzaSuya).squareRoot())
        let probabilidad = normalCDF((finalMio - finalSuyo) / desviacion)

        return MatchupProjection(
            mine: finalMio,
            theirs: finalSuyo,
            remainingMine: pendienteMio,
            remainingTheirs: pendienteSuyo,
            winProbability: min(max(probabilidad, 0.01), 0.99),
            playersLeftMine: faltanMios,
            playersLeftTheirs: faltanSuyos
        )
    }

    /// Lo que le queda por anotar.
    ///
    /// Lo reparte con el reloj, que es como lo hace Sleeper: a un jugador con
    /// 12 proyectados y medio partido por delante le quedan 6, vaya como vaya.
    /// Con el partido terminado no le queda nada, y sin empezar le queda todo.
    ///
    /// Antes se restaba lo que llevaba —`proyección − puntos`— y eso suponía
    /// que todo jugador acaba al menos en su proyección. Con media liga aún
    /// jugando el total salía siempre por arriba: 140.1 frente a los 133.6 de
    /// Sleeper en la misma jornada.
    ///
    /// Si no sabemos por dónde va el partido (equipo que ESPN no lista,
    /// datos viejos guardados), se vuelve a la cuenta de antes.
    private static func remaining(for line: PlayerLine) -> Double {
        guard let proyectado = line.projected, proyectado > 0 else { return 0 }
        if let queda = line.gameRemaining {
            return max(0, proyectado * queda)
        }
        if line.gameFinished == true { return 0 }
        return max(0, proyectado - line.points)
    }

    /// Probabilidad de que una normal estándar quede por debajo de x.
    private static func normalCDF(_ x: Double) -> Double {
        0.5 * (1.0 + erf(x / 2.0.squareRoot()))
    }
}
