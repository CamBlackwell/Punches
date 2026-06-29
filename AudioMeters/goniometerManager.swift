// GoniometerManager.swift
//
// ⚠️  TOMBSTONED — DO NOT RESTORE ⚠️
//
// GoniometerManager previously installed its own AVAudioMixerNode tap on
// bus 0. UnifiedAudioAnalyser also installs on bus 0.
// AVAudioMixerNode only supports ONE tap per bus — a second install throws
// an uncatchable ObjC exception, causing an immediate crash.
//
// GoniometerView was rewritten to read leftSamples, rightSamples, and
// phaseCorrelation directly from UnifiedAudioAnalyser (which already
// computes them). GoniometerManager is therefore completely redundant.
//
// If you need to restore goniometer-specific processing, add it as a
// method inside UnifiedAudioAnalyser so there is only ever one tap.
//
// — removed as part of crash fix, March 2026

import Foundation
// (no AudioKit import — AudioKit framework is not needed here)
