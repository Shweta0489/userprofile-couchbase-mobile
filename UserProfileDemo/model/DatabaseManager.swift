//
//  DatabaseManager.swift
//  UserProfileDemo
//
//  Created by Priya Rajagopal on 2/19/18.
//  Copyright © 2018 Couchbase Inc. All rights reserved.
//

import Foundation
import CouchbaseLiteSwift

// TODO: Remove sync stuff
class DatabaseManager {
    
    // public
    var db:Database? {
        get {
            return _db
        }
    }
    
    
    // For demo purposes only. In prod apps, credentials must be stored in keychain
    public fileprivate(set) var currentUserCredentials:(user:String,password:String)?
    
    var lastError:Error?
    
    
    // fileprivate
    fileprivate let kDBName:String = "userprofile"
    
    // This is the remote URL of the Sync Gateway (public Port)
    fileprivate let kRemoteSyncUrl = "ws://localhost:4984"
    
    fileprivate var _db:Database?
    fileprivate var _pushPullRepl:Replicator?
    fileprivate var _pushPullReplListener:ListenerToken?
    
    
    fileprivate var _applicationDocumentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last
    
    fileprivate var _applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).last
    
    static let shared:DatabaseManager = {
        
        let instance = DatabaseManager()
        instance.initialize()
        return instance
    }()
    
    func initialize() {
        //  enableCrazyLevelLogging()
    }
    // Don't allow instantiation . Enforce singleton
    private init() {
        
    }
    
    deinit {
        // Stop observing changes to the database that affect the query
        do {
            try self._db?.close()
        }
        catch  {
            
        }
    }
    
}

// MARK: Public
extension DatabaseManager {
    
    
    func openOrCreateDatabaseForUser(_ user:String, password:String, handler:(_ error:Error?)->Void) {
        do {
            var options = DatabaseConfiguration()
            guard let defaultDBPath = _applicationSupportDirectory else {
                fatalError("Could not open Application Support Directory for app!")
                return
            }
            // Create a folder for the logged in user
            let userFolderUrl = defaultDBPath.appendingPathComponent(user, isDirectory: true)
            let userFolderPath = userFolderUrl.path
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: userFolderPath) {
                try fileManager.createDirectory(atPath: userFolderPath,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
                
            }
            
            options.directory = userFolderPath
   
            print("WIll open/create DB  at path \(userFolderPath)")
            if Database.exists(withName: kDBName, inDirectory: userFolderPath) == false {
                // Load prebuilt database from App Bundle and copy over to Applications support path
                if let prebuiltPath = Bundle.main.path(forResource: kDBName, ofType: "cblite2") {
                    try Database.copy(fromPath: prebuiltPath, toDatabase: "\(kDBName)", withConfig: options)
                    
                }
                // Get handle to DB  specified path
                _db = try Database(name: kDBName, config: options)
                try createDatabaseIndexes()
                
            }
            else
            {
                // Gets handle to existing DB at specified path
                _db = try Database(name: kDBName, config: options)
                
            }
            
            // Add change listener
            /***** Uncomment for optional testing
             _db?.addChangeListener({ [weak self](change) in
             guard let `self` = self else {
             return
             }
             for docId in change.documentIDs   {
             if let docString = docId as? String {
             let doc = self._db?.getDocument(docString)
             
             print("doc.isDeleted = \(doc?.isDeleted)")
             }
             }
             
             })*****/
            currentUserCredentials = (user,password)
            handler(nil)
        }catch {
            
            lastError = error
            handler(lastError)
        }
    }
    
    
    func closeDatabaseForCurrentUser() -> Bool {
        do {
            print(#function)
            // Get handle to DB  specified path
            if let db = self.db {
                switch db.name {
                case kDBName:
                    stopAllReplicationForCurrentUser()
                    try _db?.close()
                    _db = nil
            
                default:
                    return false
                }
                
            }
            
            
            return true
            
        }
        catch {
            return false
        }
    }
    
    
    func createDatabaseIndexes() throws{
        // For searches on type property
        try _db?.createIndex(IndexBuilder.valueIndex(items:  ValueIndexItem.expression(Expression.property("type"))), withName: "typeIndex")
        try _db?.createIndex(IndexBuilder.valueIndex(items:ValueIndexItem.expression(Expression.property("name"))), withName: "nameIndex")
        try _db?.createIndex(IndexBuilder.valueIndex(items:ValueIndexItem.expression(Expression.property("airportname"))), withName: "airportIndex")
        
        // For Full text search on airports and hotels
        try _db?.createIndex(IndexBuilder.fullTextIndex(items: FullTextIndexItem.property("description")).ignoreAccents(false), withName: "descFTSIndex")
        
    }
    
    
    func startPushAndPullReplicationForCurrentUser() {
        print(#function)
        guard let remoteUrl = URL.init(string: kRemoteSyncUrl) else {
            lastError = UserProfileError.RemoteDatabaseNotReachable
            return
        }
        
        guard let user = self.currentUserCredentials?.user,let password = self.currentUserCredentials?.password  else {
            lastError = UserProfileError.UserCredentialsNotProvided
            return
        }
        
        guard let db = db else {
            lastError = UserProfileError.RemoteDatabaseNotReachable
            return
        }
        
        if _pushPullRepl != nil {
            // Replication is already started
            return
        }
        
        let dbUrl = remoteUrl.appendingPathComponent(kDBName)
        
        let config = ReplicatorConfiguration.init(database: db, target: URLEndpoint.init(url:dbUrl))
        
        config.replicatorType = .pushAndPull
        config.continuous =  true
        config.authenticator =  BasicAuthenticator(username: user, password: password)
        
        
        // This should match what is specified in the sync gateway config
        // Only pull documents from this user's channel
        let userChannel = "channel.\(user)"
        config.channels = [userChannel]
        
        _pushPullRepl = Replicator.init(config: config)
        
        _pushPullReplListener = _pushPullRepl?.addChangeListener({ [weak self] (change) in
            let s = change.status
            switch s.activity {
            case .stopped:
                print("Replication stopped")
                self?.postNotificationOnReplicationState(.stopped)
            
            case .offline:
                print("Replication offline")
                self?.postNotificationOnReplicationState(.offline)
            case .busy:
                print("Replication busy")
                self?.postNotificationOnReplicationState(.busy)
            default:
                print("Ignoring replicator status codes")
                self?.postNotificationOnReplicationState(s.activity)
            }
        })
        
        _pushPullRepl?.start()
        
    }
    
    
    
    func stopAllReplicationForCurrentUser() {
        _pushPullRepl?.stop()
        if let pushPullReplListener = _pushPullReplListener{
            print(#function)
            _pushPullRepl?.removeChangeListener(withToken:  pushPullReplListener)
            _pushPullRepl = nil
            _pushPullReplListener = nil
        }
        
    }
    
    
    fileprivate func postNotificationOnReplicationState(_ status:Replicator.ActivityLevel) {
        switch status {
        case .offline:
            NotificationCenter.default.post(Notification.notificationForReplicationOffline())
        case .connecting:
            NotificationCenter.default.post(Notification.notificationForReplicationConnecting())
        case .stopped:
            NotificationCenter.default.post(Notification.notificationForReplicationStopped())
        case .idle:
            NotificationCenter.default.post(Notification.notificationForReplicationIdle())
        case .busy:
            NotificationCenter.default.post(Notification.notificationForReplicationInProgress())
            
            
        }
    }
    
    
    
    
}

// MARK: Utils
extension DatabaseManager {
    
    fileprivate func enableCrazyLevelLogging() {
        
        Database.setLogLevel(.verbose, domain: .query)
    }
    
}

