//  YahooSettingsView.swift
//  Todo lo de Yahoo en una página, como la de Sleeper.
//
//  Sesión y ligas juntas a propósito: son un solo trámite. Entrar sin poder
//  elegir liga no sirve de nada, y elegir liga sin haber entrado es imposible,
//  así que separarlas en dos sitios solo obligaba a ir y venir.
//
//  La parte de ligas sale mucho más corta que la de Sleeper: allí hay que
//  preguntar el nombre de usuario porque no hay login, y aquí el token ya dice
//  quién eres. Dos toques: tu liga, tu equipo.

import SwiftUI

@MainActor
final class YahooLeaguesModel: ObservableObject {
    @Published var leagues: [YahooLeagueSummary] = []
    @Published var teams: [LeagueTeam] = []
    @Published var selectedLeague: YahooLeagueSummary?
    @Published var selectedTeamID: Int?
    @Published var isLoadingLeagues = false
    @Published var isLoadingTeams = false
    @Published var error: String?

    private let host = YahooHost()

    func loadLeagues() async {
        isLoadingLeagues = true
        error = nil
        defer { isLoadingLeagues = false }
        do {
            leagues = try await host.leagues()
            if leagues.isEmpty {
                error = "Tu cuenta de Yahoo no tiene ligas de NFL esta temporada."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ league: YahooLeagueSummary) async {
        selectedLeague = league
        teams = []
        selectedTeamID = nil
        isLoadingTeams = true
        error = nil
        defer { isLoadingTeams = false }
        do {
            teams = try await host.teams(in: league.leagueKey).teams
            // Yahoo marca cuál es el tuyo: no hace falta preguntarlo.
            selectedTeamID = teams.first { $0.belongs(to: "me") }?.rosterID
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Deja el selector como recién abierto: al cerrar sesión, y después de
    /// añadir una liga, para poder añadir otra sin salir de la pantalla.
    func reset() {
        leagues = []
        teams = []
        selectedLeague = nil
        selectedTeamID = nil
        error = nil
    }

    var canSave: Bool { selectedLeague != nil && selectedTeamID != nil }

    func config() -> LeagueConfig? {
        guard let liga = selectedLeague, let equipo = selectedTeamID else { return nil }
        return LeagueConfig(
            leagueID: liga.leagueKey,
            rosterID: equipo,
            teamName: teams.first { $0.rosterID == equipo }?.name,
            leagueName: liga.name,
            host: .yahoo
        )
    }
}

struct YahooSettingsView: View {
    @ObservedObject var auth: YahooAuth
    @EnvironmentObject private var model: ScoreboardModel
    @StateObject private var picker = YahooLeaguesModel()

    @State private var isWorking = false
    @State private var error: String?
    /// El código que Yahoo enseña si el salto de vuelta no llega.
    @State private var pastedCode = ""
    @State private var showPasteBox = false

    var body: some View {
        Form {
            if auth.isConnected {
                sessionSection
                leaguesSection
                teamsSection
                addSection
            } else {
                credentialsSection
                signInSection
                pasteSection
            }

            if let mensaje = error ?? picker.error {
                Section {
                    Label(mensaje, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Yahoo")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if auth.isConnected, picker.leagues.isEmpty { await picker.loadLeagues() }
        }
        .onChange(of: auth.isConnected) { _, conectado in
            if conectado { Task { await picker.loadLeagues() } }
        }
    }

    // MARK: - Sesión

    private var sessionSection: some View {
        Section {
            Label("Sesión iniciada", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.accent)
            // Lo concedido, no lo pedido. Si aquí no sale nada de fantasy,
            // ninguna petición de ligas va a funcionar por mucho que el login
            // diga que todo fue bien.
            LabeledContent("Permisos") {
                Text(auth.token?.grantedScope ?? "sin especificar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cerrar sesión", role: .destructive) {
                auth.signOut()
                picker.reset()
            }
        } footer: {
            Text("El token queda en el llavero compartido, para que el widget y el refresco en segundo plano también puedan pedir datos.")
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Client ID", text: $auth.credentials.clientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Client Secret", text: $auth.credentials.clientSecret)
            TextField("Redirect URI", text: $auth.credentials.redirectURI)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Scope (déjalo vacío)", text: Binding(
                get: { auth.credentials.scope ?? "" },
                set: { auth.credentials.scope = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text("Tu app de Yahoo")
        } footer: {
            Text("Se sacan registrando una app en developer.yahoo.com. En «Redirect URI» pega exactamente la dirección que ya viene aquí: Yahoo solo admite direcciones https, y esa es una página que no hace más que devolverte a la app. El scope déjalo vacío: pedir «fspt-r» hace que Yahoo conteste «invalid scope». El client id y el secreto no vienen en el código a propósito —un secreto metido en una app de iPhone lo puede extraer cualquiera— y se guardan en el llavero de este teléfono.")
        }
    }

    private var signInSection: some View {
        Section {
            Button {
                Task { await connect() }
            } label: {
                if isWorking {
                    HStack { ProgressView(); Text("Abriendo Yahoo…") }
                } else {
                    Text("Iniciar sesión con Yahoo")
                }
            }
            .disabled(isWorking || !auth.credentials.isComplete)
        }
    }

    /// Plan B. El salto de la página de vuelta a la app lo puede bloquear el
    /// sistema, y entonces el código se queda en pantalla.
    private var pasteSection: some View {
        Section {
            DisclosureGroup("¿No volvió sola?", isExpanded: $showPasteBox) {
                TextField("Pega aquí el código", text: $pastedCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Conectar con ese código") {
                    Task { await connectPasted() }
                }
                .disabled(isWorking || pastedCode.isEmpty)
            }
        } footer: {
            Text("Si al autorizar te quedaste en la página web con un código a la vista, cópialo y pégalo aquí.")
        }
    }

    // MARK: - Ligas

    @ViewBuilder
    private var leaguesSection: some View {
        Section {
            if picker.isLoadingLeagues {
                HStack { ProgressView(); Text("Buscando tus ligas…") }
            }
            ForEach(picker.leagues) { liga in
                Button {
                    Task { await picker.select(liga) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(liga.name)
                                .foregroundStyle(.primary)
                            Text(
                                [liga.season, liga.teamCount.map { "\($0) equipos" }]
                                    .compactMap { $0 }
                                    .joined(separator: " · ")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if liga.leagueKey == picker.selectedLeague?.leagueKey {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            if !picker.isLoadingLeagues, picker.leagues.isEmpty {
                Button("Volver a buscar") {
                    Task { await picker.loadLeagues() }
                }
            }
        } header: {
            Text("Tus ligas")
        }
    }

    @ViewBuilder
    private var teamsSection: some View {
        if picker.isLoadingTeams || !picker.teams.isEmpty {
            Section {
                if picker.isLoadingTeams {
                    HStack { ProgressView(); Text("Cargando equipos…") }
                }
                ForEach(picker.teams) { equipo in
                    Button {
                        picker.selectedTeamID = equipo.rosterID
                    } label: {
                        HStack(spacing: 10) {
                            AsyncAvatar(url: equipo.avatarURL, size: 28)
                            Text(equipo.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if equipo.rosterID == picker.selectedTeamID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("Equipos")
            } footer: {
                Text("Marcado está el equipo cuyo marcador verás. Yahoo dice cuál es el tuyo, así que ya viene elegido.")
            }
        }
    }

    @ViewBuilder
    private var addSection: some View {
        if picker.canSave {
            Section {
                Button {
                    if let nueva = picker.config() {
                        model.update(config: nueva)
                        picker.reset()
                    }
                } label: {
                    Label("Añadir esta liga", systemImage: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: - Acciones

    private func connect() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await auth.signIn()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connectPasted() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await auth.connect(pastedCode: pastedCode)
            pastedCode = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
