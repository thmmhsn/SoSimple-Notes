//
//  SoSimpleApp.swift
//  SoSimple
//
//  Created by thameemh on 2-6-26.
//

import SwiftUI
import CoreData

@main
struct SoSimpleApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
