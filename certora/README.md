This folder contains the verification of the Midnight protocol using CVL, Certora's Verification Language.

# Verified properties

## Core state and invariants

# Verification setup

# Getting started

Install the `certora-cli` package with `pip install certora-cli`.
To verify a spec, pass its configuration file in the [`certora/confs`](confs) folder to `certoraRun`.
It requires having set the `CERTORAKEY` environment variable to a valid Certora key, and to have `solc-0.8.34` in the PATH.
