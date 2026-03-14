import Foundation
import Testing

@testable import ProxyBuildInfoSupport

@Suite
struct BuildInfoVersionResolverTests {
    @Test func resolverPrefersEnvironmentVersion() throws {
        let version = BuildInfoVersionResolver.resolve(
            environment: [
                BuildInfoVersionResolver.environmentKey: "v1.2.3",
            ],
            packageDirectory: URL(fileURLWithPath: "/tmp"),
            gitDescribe: { _ in
                "v9.9.9"
            }
        )

        #expect(version == "v1.2.3")
    }

    @Test func resolverFallsBackToGitDescribe() throws {
        let version = BuildInfoVersionResolver.resolve(
            environment: [:],
            packageDirectory: URL(fileURLWithPath: "/tmp"),
            gitDescribe: { _ in
                "v2.0.0-3-gabcdef"
            }
        )

        #expect(version == "v2.0.0-3-gabcdef")
    }

    @Test func resolverFallsBackToDevWhenGitDescribeUnavailable() throws {
        struct SampleError: Error {}

        let version = BuildInfoVersionResolver.resolve(
            environment: [:],
            packageDirectory: URL(fileURLWithPath: "/tmp"),
            gitDescribe: { _ in
                throw SampleError()
            }
        )

        #expect(version == "dev")
    }
}
