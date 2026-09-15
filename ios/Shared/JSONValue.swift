//  JSONValue.swift
//  Un árbol de JSON que se puede recorrer sin saber su forma exacta.
//
//  Existe por Yahoo. Su API de fantasy nació en XML y el `?format=json` es una
//  traducción literal, así que una lista de equipos no es un array: es un
//  objeto con claves "0", "1", "2" y un "count" al lado. Y dentro de cada
//  equipo, los datos vienen en un array que mezcla diccionarios sueltos.
//
//  Navegar eso por rutas fijas —`[1].scoreboard["0"].matchups["0"]…`— se rompe
//  en cuanto Yahoo mete un campo nuevo por el camino, que es justo lo que no se
//  puede probar desde aquí. Así que no se navega: se **busca** la clave por el
//  árbol. Es más lento y da igual, son respuestas de unos kilobytes.

import Foundation

indirect enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: - Construcción

    init(_ any: Any) {
        switch any {
        case let diccionario as [String: Any]:
            self = .object(diccionario.mapValues { JSONValue($0) })
        case let lista as [Any]:
            self = .array(lista.map { JSONValue($0) })
        case let texto as String:
            self = .string(texto)
        case let numero as NSNumber:
            // En Foundation un bool también es NSNumber; se distinguen por el
            // tipo que envuelven.
            if CFGetTypeID(numero) == CFBooleanGetTypeID() {
                self = .bool(numero.boolValue)
            } else {
                self = .number(numero.doubleValue)
            }
        default:
            self = .null
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let crudo = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue(crudo)
    }

    // MARK: - Lectura

    var text: String? {
        switch self {
        case let .string(valor): return valor
        // Yahoo manda los números como texto casi siempre, pero no siempre.
        case let .number(valor):
            return valor == valor.rounded() ? String(Int(valor)) : String(valor)
        case let .bool(valor): return valor ? "1" : "0"
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case let .number(valor): return valor
        case let .string(valor): return Double(valor.replacingOccurrences(of: ",", with: ""))
        default: return nil
        }
    }

    var int: Int? { double.map { Int($0) } }

    subscript(key: String) -> JSONValue? {
        guard case let .object(diccionario) = self else { return nil }
        return diccionario[key]
    }

    /// Los elementos de una colección, venga como array de verdad o como el
    /// objeto de claves numéricas que usa Yahoo. El "count" que Yahoo pone al
    /// lado no es un elemento y se queda fuera.
    var elements: [JSONValue] {
        switch self {
        case let .array(lista):
            return lista
        case let .object(diccionario):
            return diccionario
                .compactMap { clave, valor -> (Int, JSONValue)? in
                    guard let indice = Int(clave) else { return nil }
                    return (indice, valor)
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        default:
            return []
        }
    }

    // MARK: - Búsqueda

    /// El primer valor con esa clave en todo el subárbol, por niveles.
    ///
    /// Por niveles y no en profundidad a propósito: en Yahoo el `name` del
    /// equipo está arriba y el `name` de cada jugador más abajo, así que el
    /// primero que aparece recorriendo por niveles es el que se busca.
    func find(_ key: String) -> JSONValue? {
        var pendientes: [JSONValue] = [self]
        while !pendientes.isEmpty {
            var siguiente: [JSONValue] = []
            for nodo in pendientes {
                switch nodo {
                case let .object(diccionario):
                    if let encontrado = diccionario[key] { return encontrado }
                    siguiente.append(contentsOf: diccionario.values)
                case let .array(lista):
                    siguiente.append(contentsOf: lista)
                default:
                    break
                }
            }
            pendientes = siguiente
        }
        return nil
    }

    /// Todos los valores con esa clave, sin entrar dentro de los que ya
    /// encontró: buscando "team" dentro de un enfrentamiento salen los dos
    /// equipos, no los equipos de dentro de cada equipo.
    func findAll(_ key: String) -> [JSONValue] {
        var encontrados: [JSONValue] = []
        var pendientes: [JSONValue] = [self]
        while !pendientes.isEmpty {
            var siguiente: [JSONValue] = []
            for nodo in pendientes {
                switch nodo {
                case let .object(diccionario):
                    if let acierto = diccionario[key] {
                        encontrados.append(acierto)
                        // No se sigue bajando por esta rama.
                        for (clave, valor) in diccionario where clave != key {
                            siguiente.append(valor)
                        }
                    } else {
                        siguiente.append(contentsOf: diccionario.values)
                    }
                case let .array(lista):
                    siguiente.append(contentsOf: lista)
                default:
                    break
                }
            }
            pendientes = siguiente
        }
        return encontrados
    }

    var url: URL? {
        guard let texto = text, !texto.isEmpty else { return nil }
        return URL(string: texto)
    }

    /// Atajo para lo que más se hace: `find("team_points")?.find("total")`.
    func text(_ key: String) -> String? { find(key)?.text }
    func double(_ key: String) -> Double? { find(key)?.double }
    func int(_ key: String) -> Int? { find(key)?.int }
    func url(_ key: String) -> URL? { find(key)?.url }
}
