//
//  ReSerchApp.swift
//  ReSerch
//
//  Created by Perris Aquino on 4/8/26.
//

import SwiftUI
import CoreData

@main
struct ReSerchApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
