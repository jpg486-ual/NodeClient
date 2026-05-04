//
//  ContentView.swift
//  NodeClient
//
//  Created by José Esteban Pérez González on 11/2/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        if sessionStore.isAuthenticated {
            NodeClientRootView()
        } else {
            LoginView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
}
