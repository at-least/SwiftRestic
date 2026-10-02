import SwiftUI

/// Dashboard: the three cards (`DashboardCards.swift`) over every plan.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }
            ProtectionCard(
                title: "Protection",
                plans: model.configuration.plans,
                emptyText: "Add a backup plan to start protecting your data."
            )
            NextRunsCard(plans: model.configuration.plans)
            RecentProblemsCard(repositoryID: nil)
        }
        .detailPane()
        .navigationTitle("Overview")
    }
}
