# ThunderPropagator BuildingBlocks (Project ARC) - AI Agent Instructions

## Project Overview
ThunderPropagator BuildingBlocks (Project ARC) is a .NET library of production-ready, reusable components for building high-performance, cloud-native applications. The solution targets .NET 8.0, 9.0, and 10.0 with multi-platform support (AnyCPU, x86, x64, ARM64).

## Architecture

### Layer Structure
- **Application Layer** (`src/ThunderPropagator.BuildingBlocks.Application/`): Core building blocks with NO dependencies on Infrastructure
- **Infrastructure Layer** (`src/ThunderPropagator.BuildingBlocks.Infrastructure/`): System-level components (monitoring, health checks)
- **CRITICAL**: Application must NEVER depend on Infrastructure. Verified by `ArchTests/ArchitectureTests.cs`

### Key Design Patterns

**1. Attribute-Driven Serialization**
Classes use `[JsonSerialization(CamelCase = false)]` to control JSON naming policies. See `FeederMessage.cs` and `JsonHelper.cs` for the pattern:
- `JsonSerializationAttribute` controls camelCase behavior at type level
- `IgnoreMemberAttribute` excludes properties from serialization
- `JsonHelper.JsonSerializerOptions()` checks attributes via reflection and builds custom `JsonSerializerOptions`

**2. FeederMessage Pattern**
`FeederMessage` is the core message abstraction - a dictionary-based base class implementing `IDictionary<string, object?>`, `ICorrelationIdSupport`, and `ICloneable`:
- Properties stored in internal `ConcurrentDictionary`
- Use `GetValueOrDefault<T>()` and `SetValue()` for type-safe access
- Supports correlation ID tracking via `ICorrelationIdSupport`
- Example: `FeederMessageTest.cs`

**3. ServiceConfiguration Pattern**
`ServiceConfiguration` is an abstract base for strongly-typed configuration with property change notifications:
- Implements `IServiceConfiguration`, `INotifyPropertyChanged`, `INotifyPropertyChanging`
- Uses `ConcurrentDictionary` internally for thread-safe property storage
- Custom JSON converter with `CaseConverter` for camelCase serialization
- Properties automatically tracked and serialized via reflection

**4. DisposableObject Base Class**
Consistent disposal pattern for all resources:
- Abstract base class with `IDisposable` and `IAsyncDisposable`
- Override `DisposeManagedResources()` or `DisposeUnmanagedResources()`
- Includes `AnonymousDisposable` for action-based disposal
- Thread-safe disposal tracking with `IsDisposed` flag

**5. Telemetry & Observability**
All operations should use `Telemetry.StartActivity()` for OpenTelemetry integration:
```csharp
using var activity = Telemetry.StartActivity("OperationName", ActivityKind.Internal);
activity?.SetTag("key", value);
```
- Controlled by `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable
- Meters enabled via `METER_ENABLED` environment variable
- Consistent activity naming: `{ClassName}_{MethodName}`

**6. Platform-Specific Providers**
System monitoring uses provider pattern with platform detection (Windows/Linux/macOS):
- Interface defines metric contract (e.g., `ICpuTemperatureMetricsClient`)
- Internal provider interface (e.g., `ICpuTemperatureProvider`) with platform implementations
- `CreatePlatformProvider()` factory method selects implementation via `RuntimeInformation.IsOSPlatform()`
- **NO external platform-specific packages** - uses built-in .NET APIs and CLI tools only
- Graceful degradation: returns null/empty with error messages when metrics unavailable
- See `SystemResourceMonitor/Metrics/Cpu/CpuTemperatureMetricsClient.cs` for complete example

## Build & Package Management

### Central Package Management
- **Versioning**: All versions in `Directory.Build.props` (e.g., `1.0.1-beta.5`)
- **Dependencies**: Centrally managed in `Directory.Packages.props` with `ManagePackageVersionsCentrally`
- **Floating Versions**: Framework-specific packages use wildcard versions (e.g., `Version="8.*"`)
- **Multi-targeting**: Projects target `net8.0;net9.0;net10.0` via `TargetFrameworks` in `Directory.Build.props`
- **Multi-platform**: Supports AnyCPU, x86, x64, ARM64 via `Platforms` property

### Build Commands
```powershell
dotnet restore
dotnet build -c Release
dotnet test
dotnet pack -c Release -o artifacts/pkg
```

### Configuration Flags
- `AllowUnsafeBlocks=true`: Enables unsafe code
- `GenerateDocumentationFile=true`: XML docs required for all public APIs
- `NoWarn`: Suppresses CS1591 (missing XML docs) and CS0067 (unused events)
- `LangVersion=latestmajor`: Uses latest major C# version
- Debug builds append `.Debug` suffix to package IDs
- `EnablePreviewFeatures=true` in test projects only

### Package Publishing
- All packages include `ThunderPropagator.png` and `README.md`
- Auto-generated on build when `IsPackable=true` and `GeneratePackageOnBuild=true`
- Output to `artifacts/pkg/` directory

## Testing Strategy

### Test Organization
- **Unit Tests**: `Tests/ThunderPropagator.UnitTests/` - xUnit with NSubstitute for mocking
- **Arch Tests**: `Tests/ArchTests/` - NetArchTest.Rules for architecture validation
- **Benchmarks**: BenchmarkDotNet tests in unit test project (see `CollectionHelperBenchmark.cs`)

### Running Tests
```powershell
dotnet test -c Release
# For specific test
dotnet test --filter "FullyQualifiedName~FeederMessageTest"
# For benchmarks
dotnet run -c Release --filter "*Benchmark*"
```

## CI/CD Workflows

### Release Process
- **develop** branch → `develop-beta-ci.yml` → increments beta version (e.g., `1.0.1-beta.5`)
- **release/** branch → `develop-release-ci.yml` → strips beta suffix, creates GitHub release, syncs back to develop
- GitHub Packages feed: `https://nuget.pkg.github.com/KiarashMinoo/index.json`

### Version Management
Scripts in `.github/scripts/` handle version bumps. Never manually edit version in `Directory.Build.props` outside of release workflows.

## Code Conventions

### Naming & Style
- Use `CallerArgumentExpression` for guard clauses: `Guard.Against.Null(param)`
- Internal fields: `_camelCase` with underscore prefix
- Platform names: `MacOs` not `MacOS`, `onAcPower` not `onACPower`
- NO `PerformanceCounter` package dependencies (Windows-only, avoided for cross-platform compatibility)
- Activity naming convention: `{ClassName}_{MethodName}` for telemetry
- Sealed classes in DEBUG builds become non-sealed for testability

### Serialization Extensions
All serialization helpers provide three variants (string, bytes, base64):
- **JSON**: `ToJson<T>()` / `FromJson<T>()` - System.Text.Json with attribute support
- **NetJSON**: `ToNetJson<T>()` / `FromNetJson<T>()` - NetJSON library
- **Newtonsoft**: `ToNJson<T>()` / `FromNJson<T>()` - Newtonsoft.Json
- **YAML**: `ToYaml<T>()` / `FromYaml<T>()` - YamlDotNet
- **ProtoBuf**: `ToProtoBuf<T>()` / `FromProtoBuf<T>()` - protobuf-net
- **MessagePack**: `ToMessagePack<T>()` / `FromMessagePack<T>()` - MessagePack

All extensions in `Helpers/` namespace with telemetry tracking built-in.

### Helper Utilities
- **StringHelper**: Conversion, compression (GZip, BZip2, Brotli, Deflate), Base64
- **CollectionHelper**: Collection operations with performance optimizations
- **DateTimeHelper**: Date/time utilities with NodaTime integration
- **ExceptionHelper**: Exception handling and serialization
- **GuardClauseHelper**: Custom Ardalis.GuardClauses extensions
- **Size**: File size formatting (KB, MB, GB, TB)
- **ObjectHelper**: Deep cloning, comparison, reflection utilities

### DI Registration Pattern
Infrastructure components use extension methods on `IServiceCollection`:
```csharp
services.AddSystemResourceMonitor(options => {
    options.EnableDiskHealth = true;
    options.DefaultSamplingWindowMs = 500;
});
```
See `SystemResourceMonitorExtensions.cs` for the pattern.

### Specialized Collections
- **LinkedArray<T>**: Array-backed list with index indirection for efficient insertion/removal
- **BindingDictionary<TKey, TValue>**: Dictionary with data binding support
- **GenericOrderedDictionary<TKey, TValue>**: Ordered dictionary implementation

### Security & Cryptography
- **EncryptionService**: AES encryption with configurable key sizes
- **RsaEncryptionService**: RSA encryption for asymmetric scenarios
- **PasswordGenerator**: Secure password generation with configurable complexity
- **CertificateModel**: X.509 certificate handling and management

### Change Tracking & Observability
- **IChangeTrackingObject<TKey, TValue>**: Track property changes with `BeginTracking()` / `EndTracking()`
- **ChangeType enum**: Created, Updated, Deleted, None
- **NotifiableObject**: Base class for observable objects with change notifications
- **CompressedObject**: Struct for compressed data with implicit conversions

## Documentation

- Main docs: `docs/README.md` - comprehensive catalog
- Component-level: `docs/BuildingBlocks.Application/README.md` and `docs/BuildingBlocks.Infrastructure/README.md`
- Feature docs: See `docs/SystemResourceMonitoring-*.md` for detailed feature documentation
- **IMPLEMENTATION_SUMMARY.md**: Contains recent implementation details and platform support matrices

## Common Tasks

### Adding New Metrics
1. Create metric record in `SystemResourceMonitor/Metrics/{Category}/`
2. Create `IMetricsClient<TMetric>` interface and platform-specific implementations
3. Register in `SystemResourceMonitorExtensions.cs`
4. Add property to `SystemResourceMonitorMetrics.cs`
5. Update `ISystemResourceMonitor.Collect()` method
6. Document in `docs/SystemResourceMonitoring-*.md`

### Adding New Helper
1. Create in `src/ThunderPropagator.BuildingBlocks.Application/Helpers/`
2. Make static class with extension methods
3. Use `[CallerArgumentExpression]` for parameter validation
4. Add XML documentation (required for build)
5. Add tests in `Tests/ThunderPropagator.UnitTests/`
6. Document in `docs/BuildingBlocks.Application/Helpers/README.md`

### Adding Serialization Support
Follow the three-variant pattern (string, bytes, base64):
```csharp
public static string ToFormat<T>(this T instance) { /* ... */ }
public static byte[] ToFormatBytes<T>(this T instance) { /* ... */ }
public static string ToFormatBase64<T>(this T instance) { /* ... */ }
public static T? FromFormat<T>(this string value) { /* ... */ }
public static T? FromFormatBytes<T>(this byte[] bytes) { /* ... */ }
public static T? FromFormatBase64<T>(this string base64) { /* ... */ }
```
Wrap all operations with telemetry: `Telemetry.StartActivity($"{HelperName}_{MethodName}", ActivityKind.Internal)`

### Creating Custom FeederMessage
Inherit from `FeederMessage` and add strongly-typed properties:
```csharp
public class MyMessage : FeederMessage
{
    public Guid Id
    {
        get => GetValueOrDefault(Guid.NewGuid());
        set => SetValue(value);
    }
    
    public string? Name
    {
        get => GetValueOrNull<string>();
        set => SetValue(value);
    }
}
```

### Publishing Packages
Packages auto-publish via GitHub Actions. Manual publish:
```powershell
dotnet pack -c Release -o artifacts/pkg
dotnet nuget push artifacts/pkg/*.nupkg --source github --api-key $GITHUB_TOKEN
```
