//
//  SpaceService.swift
//  RunningOrder
//
//  Created by Clément Nonn on 21/09/2020.
//  Copyright © 2020 Worldline. All rights reserved.
//

import Foundation
import Combine
import CloudKit

extension SpaceService {
    enum Error: Swift.Error {
        case noShareFound
    }
}

/// The service responsible of all the Sprint CRUD operation
class SpaceService {
    let cloudkitContainer = CloudKitContainer.shared
    var cancellables = Set<AnyCancellable>()

    func fetchShared(_ id: CKRecord.ID) -> AnyPublisher<Space, Swift.Error> {
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        cloudkitContainer.container.sharedCloudDatabase.add(operation)

        return operation.publishers()
            .perRecord
            .tryMap { result -> Space in
                if let record = result.0 {
                    return Space(underlyingRecord: record)
                } else {
                    throw SpaceManager.Error.noSpaceAvailable
                }
            }.eraseToAnyPublisher()
    }

    func save(space: Space) -> AnyPublisher<Space, Swift.Error> {
        let saveOperation = CKModifyRecordsOperation()
        saveOperation.recordsToSave = [space.underlyingRecord]

        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .utility

        saveOperation.configuration = configuration

        cloudkitContainer.currentDatabase.add(saveOperation)

        return saveOperation.publishers().perRecord
            .tryMap { Space(underlyingRecord: $0) }
            .eraseToAnyPublisher()
    }

    func getShare(for space: Space) -> AnyPublisher<CKShare, Swift.Error> {
        guard let existingShareReference = space.underlyingRecord.share else {
            fatalError("this call shouldn't be done without verfying the share optionality")
        }

        let operation = CKFetchRecordsOperation(recordIDs: [existingShareReference.recordID])
        cloudkitContainer.currentDatabase.add(operation)
        return operation.publishers()
            .completion
            .compactMap { $0?[existingShareReference.recordID] as? CKShare }
            .eraseToAnyPublisher()
    }

    func saveAndShare(space: Space) -> AnyPublisher<CKShare, Swift.Error> {
        let share = CKShare(rootRecord: space.underlyingRecord)
        share[CKShare.SystemFieldKey.title] = space.name

        let saveOperation = CKModifyRecordsOperation()
        saveOperation.recordsToSave = [space.underlyingRecord, share]

        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .utility

        saveOperation.configuration = configuration

        cloudkitContainer.currentDatabase.add(saveOperation)

        return saveOperation.publishers()
            .completion
            .map { _ in share }
            .eraseToAnyPublisher()
    }

    func delete(space: Space) -> AnyPublisher<Never, Swift.Error> {
        let deleteOperation = CKModifyRecordsOperation()
        let recordIdToDelete: CKRecord.ID
        if cloudkitContainer.mode.isOwner {
            recordIdToDelete = space.underlyingRecord.recordID
        } else {
            if let shareId = space.underlyingRecord.share?.recordID {
                recordIdToDelete = shareId
            } else {
                Logger.error.log("couldn't find the id of the share this way")
                return Fail(error: Error.noShareFound).eraseToAnyPublisher()
            }

        }
        deleteOperation.recordIDsToDelete = [recordIdToDelete]

        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .utility

        deleteOperation.configuration = configuration

        cloudkitContainer.currentDatabase.add(deleteOperation)

        return deleteOperation.publishers()
            .completion
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func acceptShare(metadata: CKShare.Metadata) -> AnyPublisher<CKShare.Metadata, Swift.Error> {
        let acceptSharesOperation = CKAcceptSharesOperation(shareMetadatas: [metadata])

        let pub = acceptSharesOperation.publishers().perShare.map { return $0.0 }.share()

        pub.sink(
            receiveFailure: { _ in },
            receiveValue: { [weak self] updatedMetadata in
                if let ownerId = updatedMetadata.ownerIdentity.userRecordID?.recordName {
                    self?.cloudkitContainer.mode = .shared(ownerName: ownerId)
                } else {
                    Logger.error.log("no owner !")
                }
            })
            .store(in: &cancellables)

        let remoteContainer = CKContainer(identifier: metadata.containerIdentifier)

        remoteContainer.add(acceptSharesOperation)

        return pub.eraseToAnyPublisher()
    }
}
