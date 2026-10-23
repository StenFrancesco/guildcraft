# Local bank capture

The bank companion saves last-known personal and guild bank contents locally. The Guild Book can synchronize complete guild-bank snapshots between compatible online clients; personal-bank snapshots remain local.

Opening a personal bank captures its purchased tabs. While open, update events are combined until the next frame: repeated known container IDs are captured once, and events without a reliable tab ID request one full scan. A committed batch refreshes the Bank page once. Guild-bank contents events are also combined; only a tab that is still selected and has supplied a contents-ready event may be captured. Tab changes before the flush require fresh readiness.

Closing a bank, reopening its session or replacing its controller cancels pending reads. Saved items and capture timestamps remain available, with uncaptured changes marked incomplete. Combat blocks item reads: personal capture can resume after combat while the bank remains open, and guild contents require a fresh readiness event. Failed, unavailable or secret data retains the existing incomplete/unavailable behavior. Pending work uses a one-shot frame update and leaves no idle polling.

Regression probes use six occupied 98-slot personal tabs. After the opening capture, three ambiguous update events require 588 item reads and one notification; three updates identifying one known container require 98 item reads and one notification. These operation counts use mocked game APIs; in-game frame-time effects still need measurement.
