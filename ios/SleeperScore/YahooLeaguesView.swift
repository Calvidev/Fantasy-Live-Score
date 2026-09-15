//  YahooLeaguesView.swift
//  Elegir liga y equipo de Yahoo, ya con la sesión iniciada.
//
//  El equivalente de `SleeperSettingsView`, pero mucho más corto: en Sleeper
//  hay que preguntar el nombre de usuario porque no hay login, y aquí el token
//  ya dice quién eres. Dos toques: tu liga, tu equipo.

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

struct YahooLeaguesView: View {
    @EnvironmentObject private var model: ScoreboardModel
    @StateObject private var picker = YahooLeaguesModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                leaguesSection
                teamsSection
                if let error = picker.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Liga de Yahoo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Añadir") {
                        if let nueva = picker.config() {
                            model.update(config: nueva)
                            dismiss()
                        }
                    }
                    .disabled(!picker.canSave)
                }
            }
            .task { await picker.loadLeagues() }
        }
    }

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
}
