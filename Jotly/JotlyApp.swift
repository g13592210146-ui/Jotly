//
//  JotlyApp.swift
//  Jotly
//
//  Created by 高星辰 on 2026/6/10.
//

import SwiftUI
import os

@main
struct JotlyApp: App {
    init() {
        JotlyLog.app.info("App launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
