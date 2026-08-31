# Ahmad (Kiarash) Minoo

**Senior .NET Backend / Full-Stack Engineer · Muscat, Oman**

I've been building software since 2003. Most of my recent work is backend and platform engineering with C# and .NET: distributed services, messaging, real-time data, caching, identity, database-heavy systems, and reusable libraries.

I still work with Angular when a feature crosses the UI, but backend architecture and systems work are where I spend most of my time.

## What I'm working with now

- C#, .NET 8/9/10, ASP.NET Core, ABP
- Clean Architecture, DDD, CQRS/MediatR, modular monoliths and microservices
- Kafka, RabbitMQ, Redis, SignalR, WebTransport, gRPC and WebSocket
- PostgreSQL, SQL Server, MongoDB, MySQL and SQLite
- OpenTelemetry, xUnit, BenchmarkDotNet, Docker, Kubernetes and CI/CD
- OAuth2/OIDC/JWT, OpenIddict and policy-based authorization

## Current projects

### ThunderPropagator

A multi-repository .NET 8/9/10 streaming project I've been building around channels, protocol contracts, data-source adapters, cluster messaging, recovery and client libraries.

The public repositories are split by responsibility rather than putting everything in one package:

- [ThunderPropagator.BuildingBlocks](https://github.com/KiarashMinoo/ThunderPropagator.BuildingBlocks) - shared abstractions and infrastructure
- [ThunderPropagator.Channels](https://github.com/KiarashMinoo/ThunderPropagator.Channels) - chat, monitoring, notifications, demos and multiplayer/game channels
- [ThunderPropagator.Feeviders](https://github.com/KiarashMinoo/ThunderPropagator.Feeviders) - adapters for Kafka, RabbitMQ, NATS, MQTT, Pulsar, ActiveMQ, Redis, cloud messaging, gRPC, WebSocket, TCP/UDP and other transports
- [ThunderPropagator.ClusterMessageBuses](https://github.com/KiarashMinoo/ThunderPropagator.ClusterMessageBuses) - pluggable inter-node message buses and fan-out implementations
- [ThunderPropagator.RecoveryHandlers](https://github.com/KiarashMinoo/ThunderPropagator.RecoveryHandlers) - snapshot recovery with Redis, MongoDB and PostgreSQL
- [ThunderPropagator.Clients](https://github.com/KiarashMinoo/ThunderPropagator.Clients) - client protocol and wire-format specification
- [ThunderPropagator.Clients.DotNet](https://github.com/KiarashMinoo/ThunderPropagator.Clients.DotNet) - .NET client implementation

Recent Channels work includes server-authoritative session state, reconnect handling, scoring and request authorization for a real-time quiz channel, with concurrency and serialization tests around the state transitions.

### IIIF.Manifest.Serializer.Net

[IIIF.Manifest.Serializer.Net](https://github.com/KiarashMinoo/IIIF.Manifest.Serializer.Net) is a version-aware .NET serializer for IIIF Presentation API 2.0, 2.1 and 3.0.

The current codebase includes:

- IIIF Presentation, Image, Auth, Content Search, Change Discovery and Content State models
- W3C-style annotations and version conversion
- navPlace, Georeference and Text Granularity extension packages
- `System.Text.Json` interoperability
- 557 unit tests plus 8 architecture tests
- roughly 82% line coverage for the core and extension packages

I've also been using the SDK to explore different persistence and change-tracking approaches:

- [IIIF.POC.ChangeTrackingLab](https://github.com/KiarashMinoo/IIIF.POC.ChangeTrackingLab) - object-graph changes and partial change sets
- [IIIF.POC.PostgreSqlRelationalV3Store](https://github.com/KiarashMinoo/IIIF.POC.PostgreSqlRelationalV3Store) - EF Core/PostgreSQL relational mapping with JSONB for extension data
- [IIIF.POC.EventSourcedManifestStore](https://github.com/KiarashMinoo/IIIF.POC.EventSourcedManifestStore) - append-only event streams with KurrentDB
- [IIIF.POC.VersionLab](https://github.com/KiarashMinoo/IIIF.POC.VersionLab) - Presentation 2.x/3.0 detection and conversion

### MinooTrading

I'm also working on a private .NET 10 modular business platform under [MinooTradingSPC](https://github.com/MinooTradingSPC). It covers areas such as accounting, billing, IAM, audit, customer/product/order management, notifications, search and scheduling, with shared CQRS, security, rate-limiting, export and workflow components.

The persistence layer is deliberately provider-oriented, with support across SQL Server, PostgreSQL, MySQL and SQLite where the module allows it.

## Other repositories

- [BlockChainLogging](https://github.com/KiarashMinoo/BlockChainLogging) - append-only/tamper-evident logging experiment
- [CaptchaWithSkiaSharp](https://github.com/KiarashMinoo/CaptchaWithSkiaSharp) - CAPTCHA image generation with SkiaSharp
- [PasswordGeneratorCLI](https://github.com/KiarashMinoo/PasswordGeneratorCLI) - password generation library and CLI
- [ZooKeeperDITester](https://github.com/KiarashMinoo/ZooKeeperDITester) - distributed locking/DI experiment with ZooKeeper
- [awesome-iiif](https://github.com/KiarashMinoo/awesome-iiif) - IIIF resources and references

## Work background

**Asl Al-Uroba · Senior .NET Full-Stack Developer · 2025-present**  
College admission and postgraduate systems, ABP/ASP.NET Core, PostgreSQL, Redis, Angular, caching, identity, background processing and internal .NET packages.

**Creative Advanced Technologies · Senior Software Developer · 2022-2024**  
EarthLink Iraq fibre-optic service systems, university software and a .NET MAUI exam engine.

**Alo Application · .NET Back-End Developer / Team Lead · 2021-2022**  
Real-time stock trading, Kafka, Lightstreamer and performance-sensitive market-data processing.

Before that I worked on MVNO/telecom systems, insurance, retail and manufacturing software, government tax services, travel software and real-estate systems.

## Writing

I write about problems I've run into while building .NET systems, especially concurrency, messaging, security and performance.

- [Medium](https://ahmadminoo.medium.com)

## Contact

- Website: [kiarashminoo.com](https://kiarashminoo.com)
- LinkedIn: [linkedin.com/in/ahmadminoo](https://linkedin.com/in/ahmadminoo)
- GitHub: [github.com/KiarashMinoo](https://github.com/KiarashMinoo)
- Email: [ahmadminoo@gmail.com](mailto:ahmadminoo@gmail.com)

I'm open to senior backend/platform roles, remote work, relocation, and open-source collaboration.
