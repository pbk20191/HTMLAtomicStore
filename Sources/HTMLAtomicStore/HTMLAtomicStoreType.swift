//
//  HTMLAtomicStoreType.swift
//  
//
//  Created by pbk on 2023/05/31.
//

import Foundation
import CoreData

public let HTMLAtomicStoreType = {
    let classType = NSStringFromClass(HTMLAtomicStore.self)
    if #available(iOS 15.0, macCatalyst 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *) {
        NSPersistentStoreCoordinator.registerStoreClass(HTMLAtomicStore.self, type: .init(rawValue: classType))
    } else {
        NSPersistentStoreCoordinator.registerStoreClass(HTMLAtomicStore.self, forStoreType: classType)
    }
    return classType
}()

@available(iOS 15.0, macCatalyst 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *)
extension NSPersistentStore.StoreType {
    
    public static let html = Self.init(rawValue: HTMLAtomicStoreType)
    
}
