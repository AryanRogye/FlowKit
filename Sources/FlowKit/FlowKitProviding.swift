//
//  FlowKitProviding.swift
//  FlowKit
//
//  Created by Aryan Rogye on 7/17/26.
//

import Foundation

protocol FlowKitProviding {
    associatedtype Content
    func run(with content: Content)
}

public struct GithubConfiguration {
    
    let clientID: String
    let callbackURL: URL
    
    public init(clientID: String, callbackURL: URL) {
        self.clientID = clientID
        self.callbackURL = callbackURL
    }
}

struct GithubFlow<T>: FlowKitProviding {
    
    typealias Content = T
    
    init() {
    }
    
    func run(with content: Content) {
        
    }
}
