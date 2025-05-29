//
//  ContentView.swift
//  mmSync
//
//  Created by Pius Friesch on 29.05.25.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @State private var moneyMoneyPath: String = ""
    @State private var verificationMessage: String = ""
    @State private var isFilePickerPresented = false

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
                ToolbarItem {
                    Button(action: detectMoneyMoneyDirectory) {
                        Label("Detect MoneyMoney", systemImage: "folder")
                    }
                }
            }
        } detail: {
            VStack {
                Text("Select an item")
                if !moneyMoneyPath.isEmpty {
                    Text("MoneyMoney Path: \(moneyMoneyPath)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !verificationMessage.isEmpty {
                        Text(verificationMessage)
                            .font(.caption)
                            .foregroundColor(verificationMessage.lowercased().contains("valid") ? .green : .red)
                    }
                    if !verificationMessage.contains("valid") {
                        Button("Select MoneyMoney Directory Manually") {
                            isFilePickerPresented = true
                        }
                        .padding(.top)
                    }
                }
            }
            .fileImporter(
                isPresented: $isFilePickerPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        let path = url.path
                        if verifyMoneyMoneyDirectory(at: path) {
                            moneyMoneyPath = path
                        } else {
                            moneyMoneyPath = "Invalid MoneyMoney directory structure"
                        }
                    }
                case .failure(let error):
                    print("Error selecting directory: \(error.localizedDescription)")
                    moneyMoneyPath = "Error selecting directory"
                }
            }
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
    
    private func verifyMoneyMoneyDirectory(at path: String) -> Bool {
        let fileManager = FileManager.default
        
        // Check if the path exists
        guard fileManager.fileExists(atPath: path) else {
            verificationMessage = "Directory does not exist"
            return false
        }
        
        // Check for required directories
        let requiredDirectories = ["Database", "Extensions", "Statements"]
        for directory in requiredDirectories {
            let dirPath = (path as NSString).appendingPathComponent(directory)
            guard fileManager.fileExists(atPath: dirPath) else {
                verificationMessage = "Missing required directory: \(directory)"
                return false
            }
        }
        
        // Check for required files in Database directory
        let databasePath = (path as NSString).appendingPathComponent("Database")
        let requiredFiles = ["MoneyMoney.sqlite"]
        for file in requiredFiles {
            let filePath = (databasePath as NSString).appendingPathComponent(file)
            guard fileManager.fileExists(atPath: filePath) else {
                verificationMessage = "Missing required file: \(file)"
                return false
            }
        }
        
        verificationMessage = "Valid MoneyMoney data directory"
        return true
    }
    
    private func detectMoneyMoneyDirectory() {
        // Get the sandboxed path and extract the actual user path
        let sandboxPath = NSHomeDirectory()
        let components = sandboxPath.components(separatedBy: "/")
        // Take the first three components: "", "Users", "pfriesch"
        let userPath = "/" + components[1...2].joined(separator: "/")
        
        let defaultPath = (userPath as NSString).appendingPathComponent("Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney")
        
        print("Checking MoneyMoney directory at: \(defaultPath)")
        print("User path: \(userPath)")
        
        if FileManager.default.fileExists(atPath: defaultPath) {
            print("Directory exists, verifying structure...")
            if verifyMoneyMoneyDirectory(at: defaultPath) {
                moneyMoneyPath = defaultPath
            } else {
                moneyMoneyPath = "Invalid MoneyMoney directory structure"
            }
        } else {
            print("Directory does not exist at path: \(defaultPath)")
            // Let's check if the parent directories exist
            let components = defaultPath.components(separatedBy: "/")
            var currentPath = ""
            for component in components {
                if !component.isEmpty {
                    currentPath += "/" + component
                    print("Checking path component: \(currentPath) - Exists: \(FileManager.default.fileExists(atPath: currentPath))")
                }
            }
            moneyMoneyPath = "MoneyMoney directory not found at default location"
            verificationMessage = ""
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
