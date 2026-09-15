//  StandingsView.swift
//  La tabla de la liga. Sale de datos que ya se piden, así que es gratis.

import SwiftUI

@MainActor
final class StandingsModel: ObservableObject {
    @Published private(set) var teams: [TeamStanding] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let service = MatchupService()

    func load(league: LeagueConfig) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            teams = try await service.standings(for: league)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StandingsView: View {
    var league: LeagueConfig
    @StateObject private var model = StandingsModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if model.teams.isEmpty && model.isLoading {
                    ProgressView().padding(.top, 40)
                } else if let error = model.error {
                    ErrorNote(text: error).padding(16)
                } else {
                    ForEach(model.teams) { team in
                        StandingRow(team: team)
                        if team.id != model.teams.last?.id {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                }
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Clasificación")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(league: league) }
        .refreshable { await model.load(league: league) }
    }

    private var header: some View {
        HStack {
            Text("#").frame(width: 22, alignment: .leading)
            Text("Equipo")
            Spacer()
            Text("PF").frame(width: 54, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.4))
        .padding(.bottom, 8)
    }
}

struct StandingRow: View {
    var team: TeamStanding

    var body: some View {
        HStack(spacing: 10) {
            Text("\(team.rank)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(team.isMine ? Theme.accent : Color.white.opacity(0.45))
                .frame(width: 22, alignment: .leading)

            AsyncAvatar(url: team.avatarURL, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(team.name)
                    .font(.system(size: 14, weight: team.isMine ? .bold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(team.record)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(team.pointsFor.fantasyPoints)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("en contra \(team.pointsAgainst.fantasyPoints)")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 8)
        .background(
            team.isMine ? Theme.accent.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
