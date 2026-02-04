# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Rewritten from scratch.

## [0.052] - 2010-04-02

### Changed
- miniswarm tests are given less time before giving up.

### Removed
- 'bad' test (checking if port was opened twice) removed.
- `t/900_data/950_torrents/951_single.torrent` removed to prevent OOM errors on limited resources.

### Notes
- Last stable version before the rewrite.

## [0.051] - 2009-09-12

### Fixed
- DHT nodes found in metadata are now handled according to spec.

### Added
- New script `/scripts/net-bittorrent.pl` installed with distribution.

## [0.050] - 2009-02-13

### Changed
- `Net::BitTorrent::Peer` objects have their sockets closed and removed *before* calling any peer_disconnect callbacks.
- Reasons handed to peer_disconnect callbacks are now language agnostic.
- Message Stream Encryption (MSE) enabled by default with plaintext fallback.
- Shorter waiting period before filling requests (15s -> 3s).
- Default for number of allowed connections per host changed (2 -> 1).

### Fixed
- Fixed major bug related to outgoing HAVE packets.

### Added
- New demonstration script: `/tatoeba/005-console.pl`.

## [0.049] - 2009-01-05

### Changed
- `Net::BitTorrent::Torrent->peers()` is now public.
- Lists of potential peers kept by source rather than in `Net::BitTorrent::Torrent`.
- Resume system replaced with a Rasterbar-like implementation.

### Added
- New demonstrations: `/tatoeba/002-debug.pl`, `/tatoeba/003-threads.pl`, `/tatoeba/004-resume.pl`.

## [0.046] - 2008-12-30

### Changed
- `Net::BitTorrent::Torrent::HTTP->url()` and `Net::BitTorrent::Torrent::UDP->url()` are now public.

### Fixed
- Fixed bug where `Net::BitTorrent->new()` failed to set defaults if no arguments were passed.

## [0.045] - 2008-12-26

### Added
- [Beta] Torrent resume system.

### Fixed
- Close related sockets on `N::B::DESTROY` to avoid `FIN_WAIT1` on Win32.
- DHT functionality fixes.

## [0.042] - 2008-12-04

### Added
- `as_string()` is now a public method in all classes.

### Fixed
- Fixed crash bug on failure to write data to disk.

## [0.040] - 2008-12-01

### Added
- Torrents can now be paused, stopped, and started (alpha).
- UDP tracker support.

### Changed
- Net::BitTorrent rewritten from scratch.
- `Net::BitTorrent::Session::*` renamed to `Net::BitTorrent::Torrent::*`.
- PeerID spec changed.

### Fixed
- Fixed CLOSE_WAIT socket flooding.

## [0.027_001] - 2008-XX-XX

### Notes
- Net::BitTorrent is going through a rewrite. Don't use this.

## [0.025] - 2008-07-01

### Fixed
- Fixed crash bugs in packet dispatch table and `Data::Dumper` usage.
- Fixed non-critical bug in N::B::S::Peer when a connected peer goes ((poof)).

## [0.024] - 2008-07-01

### Changed
- Entire API changed.

### Added
- New DHT-related callback: `peer_outgoing_port`.

## [0.022] - 2008-05-24

### Added
- Callback system complete.

## [0.020] - 2008-05-22

### Added
- New methods for alternative event processing: `process_connections`, `process_timers`.

### Fixed
- Fixed bug in `Piece.pm` regarding file size check.
- Extended charset filenames handled properly on Win32.

## [0.018] - 2008-04-24

### Added
- Transfer limits (kBps_up, kBps_down).

## [0.015] - 2008-04-11

### Notes
- Dup of 0.013 to fix bad M::B dist.

## [0.013] - 2008-04-11

### Fixed
- Bug causing files to be re-opened every time they are read.

### Changed
- Removed peer_outgoing_packet callback.

## [0.008] - 2008-04-01

### Added
- It actually exists.
