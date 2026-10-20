# @lepton-desk/servo-linux-x64

Servo for [Lepton](https://github.com/lepton-desk/lepton), **experimental**: `lib/liblepton_servo.so`, the bridge from `servo/bridge` with Servo 0.6 inside, built and stripped in CI (`servo-bridge` workflow).

```bash
npm install -D @lepton-desk/servo-linux-x64@beta
npx lepton build --servo
```

`lepton build --servo` finds the library here and links the core to it. Without the package it names the directory with `LEPTON_SERVO_LIB`.

The library contains Servo, under the Mozilla Public License 2.0 (`LICENSE-MPL`); the bridge itself is MIT or Apache-2.0. Servo's source is at https://github.com/servo/servo.
