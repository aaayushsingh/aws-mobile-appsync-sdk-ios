//
// Copyright 2010-2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
// http://aws.amazon.com/apache2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//

import Dispatch
import os.log

protocol MQTTSubscritionWatcher {
    func getIdentifier() -> Int
    func getTopics() -> [String]
    func messageCallbackDelegate(data: Data)
    func disconnectCallbackDelegate(error: Error)
}

class SubscriptionsOrderHelper {
    var count = 0
    var previousCall = Date()
    var pendingCount = 0
    var dispatchLock = DispatchQueue(label: "SubscriptionsQueue")
    var waitDictionary = [0: true]
    static let sharedInstance = SubscriptionsOrderHelper()
    
    func getLatestCount() -> Int {
        count = count + 1
        waitDictionary[count] = false
        return count
    }
    
    func markDone(id: Int) {
        waitDictionary[id] = true
    }
    
    func shouldWait(id: Int) -> Bool {
        for i in 0..<id {
            if (waitDictionary[i] == false) {
                return true
            }
        }
        return false
    }
    
}

/// A `AWSAppSyncSubscriptionWatcher` is responsible for watching the subscription, and calling the result handler with a new result whenever any of the data is published on the MQTT topic. It also normalizes the cache before giving the callback to customer.
public final class AWSAppSyncSubscriptionWatcher<Subscription: GraphQLSubscription>: MQTTSubscritionWatcher, Cancellable {
    
    weak var client: AppSyncMQTTClient?
    weak var httpClient: AWSNetworkTransport?
    let subscription: Subscription?
    let handlerQueue: DispatchQueue
    let resultHandler: SubscriptionResultHandler<Subscription>
    internal var subscriptionTopic: [String]?
    let store: ApolloStore
    public let uniqueIdentifier = SubscriptionsOrderHelper.sharedInstance.getLatestCount()
    
    init(client: AppSyncMQTTClient, httpClient: AWSNetworkTransport, store: ApolloStore, subscription: Subscription, handlerQueue: DispatchQueue, resultHandler: @escaping SubscriptionResultHandler<Subscription>) {
        self.client = client
        self.httpClient = httpClient
        self.store = store
        self.subscription = subscription
        self.handlerQueue = handlerQueue
        self.resultHandler = { (result, transaction, error) in
            handlerQueue.async {
                resultHandler(result, transaction, error)
            }
        }
        // start the subscriptionr request process on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.startSubscription()
        }
    }
    
    func getIdentifier() -> Int {
        return uniqueIdentifier
    }
    
    func startSubscription()  {
        do {
            while (SubscriptionsOrderHelper.sharedInstance.shouldWait(id: self.uniqueIdentifier)) {
                sleep(4)
            }
            
            let _ = try self.httpClient?.sendSubscriptionRequest(operation: subscription!, completionHandler: { (response, error) in
                SubscriptionsOrderHelper.sharedInstance.markDone(id: self.uniqueIdentifier)
                if let response = response {
                    do {
                        let subscriptionResult = try AWSGraphQLSubscriptionResponseParser(body: response).parseResult()
                        if let subscriptionInfo = subscriptionResult.subscriptionInfo {
                            self.subscriptionTopic = subscriptionResult.newTopics
                            self.client?.addWatcher(watcher: self, topics: subscriptionResult.newTopics!, identifier: self.uniqueIdentifier)
                            self.client?.startSubscriptions(subscriptionInfo: subscriptionInfo)
                        }
                    } catch {
                        self.resultHandler(nil, nil, AWSAppSyncSubscriptionError(additionalInfo: error.localizedDescription, errorDetails: nil))
                    }
                } else if let error = error {
                    
                    self.resultHandler(nil, nil, AWSAppSyncSubscriptionError(additionalInfo: error.localizedDescription, errorDetails: nil))
                }
            })
        } catch {
            resultHandler(nil, nil, AWSAppSyncSubscriptionError(additionalInfo: error.localizedDescription, errorDetails: nil))
        }
        
    }
    
    func getTopics() -> [String] {
        return subscriptionTopic ?? [String]()
    }
    
    func disconnectCallbackDelegate(error: Error) {
        self.resultHandler(nil, nil, error)
    }
    
    func messageCallbackDelegate(data: Data) {
        do {
            AppSyncLog.verbose("Received message in messageCallbackDelegate")
            
            guard let _ = NSString(data: data, encoding: String.Encoding.utf8.rawValue) else {
                AppSyncLog.error("Unable to convert message data to String using UTF8 encoding")
                AppSyncLog.debug("Message data is [\(data)]")
                return
            }
           
            guard let jsonObject = try JSONSerializationFormat.deserialize(data: data) as? JSONObject else {
                AppSyncLog.error("Unable to deserialize message data")
                AppSyncLog.debug("Message data is [\(data)]")
                return
            }
            
            let response = GraphQLResponse(operation: subscription!, body: jsonObject)
            
            firstly {
                try response.parseResult(cacheKeyForObject: self.store.cacheKeyForObject)
                }.andThen { (result, records) in
                    let _ = self.store.withinReadWriteTransaction { transaction in
                        self.resultHandler(result, transaction, nil)
                    }
                    
                    if let records = records {
                        self.store.publish(records: records, context: nil).catch { error in
                            preconditionFailure(String(describing: error))
                        }
                    }
                }.catch { error in
                    self.resultHandler(nil, nil, error)
            }
        } catch {
            self.resultHandler(nil, nil, error)
        }
    }
    
    deinit {
        // call cancel here before exiting
        cancel()
    }    
    
    /// Cancel any in progress fetching operations and unsubscribe from the messages.
    public func cancel() {
        client?.stopSubscription(subscription: self)
    }
}

