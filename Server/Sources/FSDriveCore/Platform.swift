// The C library of the platform, re-exported so every module that imports FSDriveCore
// can call POSIX functions on macOS (Darwin) and Linux (glibc, or musl for the fully
// static build that runs on QNAP).
#if canImport(Darwin)
@_exported import Darwin
#elseif canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#endif

#if canImport(CryptoKit)
@_exported import CryptoKit
#else
@_exported import Crypto
#endif
