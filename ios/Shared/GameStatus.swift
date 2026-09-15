//  GameStatus.swift
//  Qué partidos de la NFL han terminado ya.
//
//  Sin esto, la proyección de un equipo sigue contando lo que "le queda por
//  anotar" a un jugador cuyo partido acabó hace horas. Es justo lo que hacía
//  que la proyección saliera alta: Kittle proyectaba 10.06, hizo 3.20 y su
//  partido estaba cerrado, pero se le seguían suponiendo 6.86 puntos más.
//
//  Y no basta con saber si acabó: mientras se juega, lo que le queda por
//  anotar a un jugador se encoge con el reloj. Sleeper reparte la proyección
//  a lo largo del partido —a mitad del segundo cuarto solo le supone la mitad
//  de lo que proyectaba— y por eso su número baja durante la tarde mientras
//  el nuestro se quedaba clavado en el máximo.
//
//  Sleeper no publica ni el estado del partido ni el total proyectado de un
//  equipo, así que se le pregunta al marcador público de ESPN, que es la misma
//  fuente que ya usa la herramienta web.

import Foundation

struct GameStatus: Codable {
    /// Abreviaturas de los equipos cuyo partido ya ha terminado.
    var finishedTeams: Set<String>
    /// Equipos que están jugando ahora mismo.
    var playingTeams: Set<String>
    /// Qué fracción del partido le queda a cada equipo que está jugando, de 1
    /// (no ha empezado) a 0 (terminado). Opcional porque los datos guardados
    /// por versiones anteriores no lo traen.
    var remainingFraction: [String: Double]?
    var savedAt: Date
    /// Jornada cerrada entera. Es lo que se usa al mirar una semana pasada:
    /// no le queda nada por jugar a nadie, y el marcador de ESPN —que va de
    /// los partidos de HOY— no dice nada de aquella.
    var allFinished: Bool?

    /// El estado de una jornada que ya terminó.
    static func closed() -> GameStatus {
        GameStatus(
            finishedTeams: [], playingTeams: [],
            remainingFraction: nil, savedAt: Date(), allFinished: true
        )
    }

    func hasFinished(_ team: String?) -> Bool {
        if allFinished == true { return true }
        guard let team, !team.isEmpty else { return false }
        return finishedTeams.contains(GameStatus.normalize(team))
    }

    /// Cuánto partido le queda por delante, de 1 a 0. Nil cuando no sabemos
    /// nada de ese equipo esta jornada: quien pregunta decide qué hacer.
    func remaining(for team: String?) -> Double? {
        if allFinished == true { return 0 }
        guard let team, !team.isEmpty else { return nil }
        let clave = GameStatus.normalize(team)
        if finishedTeams.contains(clave) { return 0 }
        if let guardada = remainingFraction?[clave] { return guardada }
        if playingTeams.contains(clave) { return nil }
        return nil
    }

    /// ESPN y Sleeper no escriben igual todas las abreviaturas.
    static func normalize(_ team: String) -> String {
        let alias = [
            "WSH": "WAS", "JAC": "JAX", "LA": "LAR",
            "SD": "LAC", "OAK": "LV", "STL": "LAR",
        ]
        let mayus = team.uppercased()
        return alias[mayus] ?? mayus
    }
}

actor GameStatusStore {
    static let shared = GameStatusStore()

    private let endpoint = URL(
        string: "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
    )!
    private let fileName = "game-status.json"
    /// En domingo esto cambia cada pocos minutos.
    private let maxAge: TimeInterval = 180
    private var memory: GameStatus?

    private var fileURL: URL {
        SharedStore.containerURL.appendingPathComponent(fileName)
    }

    func cached() -> GameStatus? {
        if let memory { return memory }
        guard
            let data = try? Data(contentsOf: fileURL),
            let guardado = try? SharedJSON.decoder.decode(GameStatus.self, from: data)
        else {
            return nil
        }
        memory = guardado
        return guardado
    }

    @discardableResult
    func refreshIfNeeded() async -> GameStatus? {
        if let guardado = cached(), Date().timeIntervalSince(guardado.savedAt) < maxAge {
            return guardado
        }
        guard let data = try? await SleeperAPI.shared.download(endpoint) else {
            return cached()
        }
        guard let nuevo = Self.parse(data) else { return cached() }

        memory = nuevo
        if let codificado = try? SharedJSON.encoder.encode(nuevo) {
            try? codificado.write(to: fileURL, options: .atomic)
        }
        return nuevo
    }

    // MARK: - Parseo del marcador de ESPN

    private struct Respuesta: Decodable {
        struct Evento: Decodable {
            struct Competicion: Decodable {
                struct Competidor: Decodable {
                    struct Equipo: Decodable { let abbreviation: String? }
                    let team: Equipo?
                }
                struct Estado: Decodable {
                    struct Tipo: Decodable {
                        let completed: Bool?
                        let state: String?  // "pre", "in", "post"
                    }
                    let type: Tipo?
                    /// Segundos que quedan del cuarto en curso.
                    let clock: Double?
                    /// 1 a 4; de 5 en adelante es prórroga.
                    let period: Int?

                    private enum Clave: String, CodingKey {
                        case type, clock, period, displayClock
                    }

                    /// A mano y sin lanzar: si ESPN cambiara el reloj de número
                    /// a texto —o al revés—, la decodificación automática
                    /// tiraría el marcador entero y dejaríamos de saber
                    /// siquiera qué partidos han terminado. Aquí lo peor que
                    /// pasa es que el reloj se quede a nil.
                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: Clave.self)
                        type = try? c.decodeIfPresent(Tipo.self, forKey: .type)
                        period = try? c.decodeIfPresent(Int.self, forKey: .period)

                        if let segundos = try? c.decodeIfPresent(Double.self, forKey: .clock) {
                            clock = segundos
                        } else if let texto = try? c.decodeIfPresent(String.self, forKey: .clock) {
                            clock = Estado.segundos(texto)
                        } else if let texto = try? c.decodeIfPresent(
                            String.self, forKey: .displayClock
                        ) {
                            clock = Estado.segundos(texto)
                        } else {
                            clock = nil
                        }
                    }

                    /// "3:50" → 230.
                    static func segundos(_ texto: String?) -> Double? {
                        guard let texto else { return nil }
                        let partes = texto.split(separator: ":")
                        guard partes.count == 2,
                              let minutos = Double(String(partes[0])),
                              let segundos = Double(String(partes[1]))
                        else { return nil }
                        return minutos * 60 + segundos
                    }
                }
                let competitors: [Competidor]?
                let status: Estado?
            }
            let competitions: [Competicion]?
        }
        let events: [Evento]?
    }

    static func parse(_ data: Data) -> GameStatus? {
        guard let respuesta = try? JSONDecoder().decode(Respuesta.self, from: data) else {
            return nil
        }
        var terminados = Set<String>()
        var jugando = Set<String>()
        var restante: [String: Double] = [:]

        for evento in respuesta.events ?? [] {
            for competicion in evento.competitions ?? [] {
                let tipo = competicion.status?.type
                let acabado = tipo?.completed == true || tipo?.state == "post"
                let enJuego = tipo?.state == "in"
                guard acabado || enJuego else { continue }

                let queda = acabado ? 0 : fraccionRestante(competicion.status)

                for competidor in competicion.competitors ?? [] {
                    guard let abreviatura = competidor.team?.abbreviation else { continue }
                    let normalizada = GameStatus.normalize(abreviatura)
                    restante[normalizada] = queda
                    if acabado {
                        terminados.insert(normalizada)
                    } else {
                        jugando.insert(normalizada)
                    }
                }
            }
        }
        return GameStatus(
            finishedTeams: terminados,
            playingTeams: jugando,
            remainingFraction: restante,
            savedAt: Date(),
            allFinished: nil
        )
    }

    /// Cuánto partido queda, de 1 a 0, a partir del cuarto y del reloj.
    ///
    /// Un partido son cuatro cuartos de quince minutos. En el descanso ESPN
    /// deja el reloj a cero con el cuarto en 2, que es justo la mitad, así que
    /// no hay que tratarlo aparte. En prórroga la cuenta se ha acabado ya: lo
    /// que queda es casi nada, pero no cero, porque todavía se puede anotar.
    private static func fraccionRestante(_ estado: Respuesta.Evento.Competicion.Estado?) -> Double {
        guard let estado, let cuarto = estado.period else { return 1 }
        if cuarto > 4 { return 0.05 }

        let segundosDelCuarto = min(max(estado.clock ?? 900, 0), 900)
        let cuartosEnteros = Double(max(0, 4 - cuarto))
        let segundos = segundosDelCuarto + cuartosEnteros * 900
        return min(max(segundos / 3_600, 0), 1)
    }
}
