//  WeekStats.swift
//  Las estadísticas de la jornada: yardas, recepciones y touchdowns.
//
//  El marcador de Sleeper solo da puntos de fantasy. Para poder decir *qué*
//  hizo un jugador hace falta otra llamada, `/stats/nfl/{tipo}/{año}/{jornada}`,
//  que devuelve la línea estadística de todos los jugadores de esa jornada.
//
//  Como el catálogo: la descarga solo la app y la deja en el grupo de apps; el
//  widget y la Live Activity leen el archivo y nunca pagan la descarga.

import Foundation

struct WeekStats: Codable {
    /// player_id -> { "rec_yd": 88, "rec_td": 1, ... }
    var byPlayer: [String: [String: Double]]
    var season: String
    var week: Int
    var savedAt: Date

    /// "6 rec · 88 yds · 1 TD". Nil cuando el jugador no ha hecho nada todavía.
    func line(for playerID: String, position: String?) -> String? {
        guard let stats = byPlayer[playerID] else { return nil }
        var partes: [String] = []

        func valor(_ clave: String) -> Double { stats[clave] ?? 0 }
        func entero(_ numero: Double) -> String { String(Int(numero.rounded())) }

        let pasando = valor("pass_yd") != 0 || valor("pass_td") != 0
        let corriendo = valor("rush_att") != 0 || valor("rush_yd") != 0
        let recibiendo = valor("rec") != 0 || valor("rec_yd") != 0

        // Un QB puede correr, y un RB recibir: se enseña todo lo que tenga,
        // empezando por lo suyo.
        if pasando {
            partes.append("\(entero(valor("pass_yd"))) yds aéreas")
            if valor("pass_td") > 0 { partes.append("\(entero(valor("pass_td"))) TD") }
            if valor("pass_int") > 0 { partes.append("\(entero(valor("pass_int"))) INT") }
        }
        if corriendo {
            partes.append("\(entero(valor("rush_att"))) acar · \(entero(valor("rush_yd"))) yds")
            if valor("rush_td") > 0 { partes.append("\(entero(valor("rush_td"))) TD") }
        }
        if recibiendo {
            partes.append("\(entero(valor("rec"))) rec · \(entero(valor("rec_yd"))) yds")
            if valor("rec_td") > 0 { partes.append("\(entero(valor("rec_td"))) TD") }
        }

        if partes.isEmpty, position?.uppercased() == "K" {
            let goles = valor("fgm")
            let extras = valor("xpm")
            if goles > 0 { partes.append("\(entero(goles)) FG") }
            if extras > 0 { partes.append("\(entero(extras)) PAT") }
        }

        if partes.isEmpty {
            // Defensas y todo lo demás: al menos las capturas y las robadas.
            let capturas = valor("sack") + valor("def_sack")
            let robos = valor("int") + valor("def_int")
            if capturas > 0 { partes.append("\(entero(capturas)) saq") }
            if robos > 0 { partes.append("\(entero(robos)) INT") }
        }

        return partes.isEmpty ? nil : partes.joined(separator: " · ")
    }
}

extension WeekStats {
    /// Una jornada suelta, sin pasar por la caché.
    ///
    /// La caché guarda **una** jornada y es la de hoy, que es la que necesitan
    /// el widget y la Live Activity. Al mirar atrás no se puede pisar: se pide
    /// aparte y se usa solo para esa pantalla.
    static func fetch(season: String, week: Int) async -> WeekStats? {
        guard
            let crudas: [String: [String: Double]] = try? await SleeperAPI.shared
                .get("/stats/nfl/regular/\(season)/\(week)")
        else { return nil }
        return WeekStats(byPlayer: crudas, season: season, week: week, savedAt: Date())
    }
}

actor WeekStatsStore {
    static let shared = WeekStatsStore()

    private let fileName = "week-stats.json"
    /// Durante un partido esto cambia cada pocos minutos.
    private let maxAge: TimeInterval = 120
    private var memory: WeekStats?

    private var fileURL: URL {
        SharedStore.containerURL.appendingPathComponent(fileName)
    }

    /// Lo que hay guardado, sin red. Es lo que usan el widget y la Live Activity.
    func cached() -> WeekStats? {
        if let memory { return memory }
        guard
            let data = try? Data(contentsOf: fileURL),
            let guardadas = try? SharedJSON.decoder.decode(WeekStats.self, from: data)
        else {
            return nil
        }
        memory = guardadas
        return guardadas
    }

    /// Descarga la jornada si lo guardado es viejo o es de otra semana.
    @discardableResult
    func refreshIfNeeded(season: String, week: Int) async -> WeekStats? {
        if let guardadas = cached(),
           guardadas.season == season,
           guardadas.week == week,
           Date().timeIntervalSince(guardadas.savedAt) < maxAge {
            return guardadas
        }

        guard
            let crudas: [String: [String: Double]] = try? await SleeperAPI.shared
                .get("/stats/nfl/regular/\(season)/\(week)")
        else {
            return cached()
        }

        let nuevas = WeekStats(
            byPlayer: crudas, season: season, week: week, savedAt: Date()
        )
        memory = nuevas
        if let data = try? SharedJSON.encoder.encode(nuevas) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return nuevas
    }
}
