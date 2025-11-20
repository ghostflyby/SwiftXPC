// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
//import Distributed
//import Foundation
//
//extension XPCEncoder: DistributedTargetInvocationEncoder {
//	public typealias SerializationRequirement = XPCBaseMarshal
//
//	public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
//
//	}
//
//	public mutating func recordArgument<Value>(_ argument: RemoteCallArgument<Value>) throws {
//	}
//
//	public mutating func recordErrorType<E>(_ type: E.Type) throws where E: Error {
//
//	}
//
//	public mutating func recordReturnType<R>(_ type: R.Type) throws {
//
//	}
//
//	public mutating func doneRecording() throws {
//
//	}
//
//}
//
//extension XPCDecoder: DistributedTargetInvocationDecoder {
//	public typealias SerializationRequirement = XPCBaseMarshal
//
//	public mutating func decodeGenericSubstitutions() throws -> [any Any.Type] {
//
//	}
//
//	public mutating func decodeNextArgument<Argument>() throws -> Argument {
//
//	}
//
//	public mutating func decodeErrorType() throws -> (any Any.Type)? {
//
//	}
//
//	public mutating func decodeReturnType() throws -> (any Any.Type)? {
//
//	}
//
//}
//
//struct XPCResultHandler: DistributedTargetInvocationResultHandler {
//	func onReturnVoid() async throws {
//
//	}
//
//	func onThrow<Err>(error: Err) async throws where Err: Error {
//
//	}
//
//	typealias SerializationRequirement = XPCBaseMarshal
//	func onReturn<Success: SerializationRequirement>(value: Success) async throws {
//
//	}
//
//}
//
//final class MyActorSystem: DistributedActorSystem {
//
//
//	func resolve<Act>(id: UUID, as actorType: Act.Type) throws -> Act?
//	where Act: DistributedActor, UUID == Act.ID {
//
//	}
//
//	func assignID<Act>(_ actorType: Act.Type) -> UUID
//	where Act: DistributedActor, UUID == Act.ID {
//
//	}
//
//	func actorReady<Act>(_ actor: Act) where Act: DistributedActor, UUID == Act.ID {
//
//	}
//
//	func resignID(_ id: UUID) {
//	}
//
//	func makeInvocationEncoder() -> XPCEncoder {
//
//	}
//
//	func remoteCall<Act, Err, Res>(on actor: Act, target: RemoteCallTarget, invocation: inout XPCEncoder, throwing: Err.Type, returning: Res.Type) async throws -> Res where Act : DistributedActor, Err : Error, UUID == Act.ID {
//
//	}
//		func remoteCallVoid<Act, Err>(
//		on actor: Act, target: RemoteCallTarget, invocation: inout XPCEncoder,
//		throwing: Err.Type
//	) async throws where Act: DistributedActor, Err: Error, UUID == Act.ID {
//
//	}
//
//	func invokeHandlerOnReturn(
//		handler: XPCResultHandler, resultBuffer: UnsafeRawPointer, metatype: any Any.Type
//	) async throws {
//
//	}
//
//}
