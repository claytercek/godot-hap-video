# Changelog

## 0.1.0 (2026-07-13)


### Features

* add HapPlayer demo scene and manual smoke test scripts ([ee62149](https://github.com/claytercek/godot-hap-video/commit/ee62149e7dd1d0441b85c2c1c277be658ad738dc))
* **build:** add sanitize= and fuzz= SCons build variants ([e5bab88](https://github.com/claytercek/godot-hap-video/commit/e5bab88477ca9729b3ae197ea73d914650249aa4))
* **core:** add DecodeScheduler tying demux/decode to the outer pool ([50597f1](https://github.com/claytercek/godot-hap-video/commit/50597f17ad9f4592594276c4f0dd7cf4f53e1ad9))
* **core:** add Hap1 demuxer, decoder, and Godot shims ([fae1aea](https://github.com/claytercek/godot-hap-video/commit/fae1aeaef22cd609395ed27a9329ef0a6e8f62a5))
* **core:** add Hap5 and Hap7 pass-through variant support ([0a11ab7](https://github.com/claytercek/godot-hap-video/commit/0a11ab707fb10594bc7f2f0925e61311fbc954fc))
* **core:** add inner thread pool for parallel chunked decode ([b23b724](https://github.com/claytercek/godot-hap-video/commit/b23b724ec09e73dcd57eb44d051ff4955ff854d1))
* **core:** add outer thread pool, frame queue, retire ring ([8859289](https://github.com/claytercek/godot-hap-video/commit/8859289241e733c0f48bedb53e01471c99ec43c9))
* **core:** decode backward for reverse playback ([1062484](https://github.com/claytercek/godot-hap-video/commit/1062484b91f3002ce889cdbd6ec689c705486b92))
* **core:** extract HapPlayer's pump math into headless-testable logic ([b9515f4](https://github.com/claytercek/godot-hap-video/commit/b9515f446c7ed59031df81cdfe905a0da193087e))
* **godot:** add HapPlayer power-user node ([f913b50](https://github.com/claytercek/godot-hap-video/commit/f913b5065b3553fc4d54087a57192ec0e87d5f66))
* **godot:** expose direct pump-driving API on HapVideoStreamPlayback ([3830758](https://github.com/claytercek/godot-hap-video/commit/38307582f7a1fb4ef75b2f593967fd5201bcb466))
* **gpu:** add YCoCg decode compute shader for HapY/HapM ([bcb1a94](https://github.com/claytercek/godot-hap-video/commit/bcb1a946de521f2893c71b338bb34b24802c5bdf))
* **gpu:** ring-of-3 for pass-through/BC textures, async decode wiring ([0325a13](https://github.com/claytercek/godot-hap-video/commit/0325a13095aff211b55074cee81e66d34ef70f04))
* repo skeleton with SCons, vendored deps, empty extension, CI ([90ece50](https://github.com/claytercek/godot-hap-video/commit/90ece50e7fcb20eda60d43b97d130f78ef2e7ca5))


### Bug Fixes

* **build:** always prefix shared lib output with "lib" ([15a692a](https://github.com/claytercek/godot-hap-video/commit/15a692a4497307c41ecada06a3e43711c6444451))
* **build:** use env.Glob for MSVC core test object reuse ([8a4d745](https://github.com/claytercek/godot-hap-video/commit/8a4d745307540d67dff90b3bf89949ab22d2003f))
* **core:** guard scheduler seek state with a mutex ([24457ce](https://github.com/claytercek/godot-hap-video/commit/24457ce166c3fe9ffed4ce39d73f0153d3000e93))
* **core:** join DecodeScheduler's stream jobs before teardown ([7f80fd4](https://github.com/claytercek/godot-hap-video/commit/7f80fd4b084991b186f16e3c5272acaa76a2c4db))
* **core:** reject sample counts that exceed the file size ([47e5137](https://github.com/claytercek/godot-hap-video/commit/47e51375a8f7c907c4ea9e13869ba365df27b703))
* **godot:** add missing _get_rid override and configurable alpha ([7200a19](https://github.com/claytercek/godot-hap-video/commit/7200a196d0bea1d53ecaf0d4ff60be4cb04be8be))
* **godot:** bind HapVideoStream.file so it's settable from GDScript ([4e839bb](https://github.com/claytercek/godot-hap-video/commit/4e839bbb94b11180c9291efa99d6f40222f99332))
* **godot:** honor stream_position set before async open completes ([a97a6ae](https://github.com/claytercek/godot-hap-video/commit/a97a6aeca27cbbf4ca80de0d78458f7f3699b73a))
* **godot:** make HapVideoStreamPlayback instantiable, globalize paths ([fc86aaf](https://github.com/claytercek/godot-hap-video/commit/fc86aaf74105dae3e938cf6d6a6faad2f63f2340))
* **godot:** register ResourceFormatLoader at SERVERS init level ([b46e8e1](https://github.com/claytercek/godot-hap-video/commit/b46e8e1a60ade345c6f5bc08137e9c5b5508d320))
* **gpu:** repair YCoCg compute dispatch and teardown ([ed4f9a6](https://github.com/claytercek/godot-hap-video/commit/ed4f9a6ad7e6f34d73a5bf27c0f5c69d80ba6c30))
* **hap:** match hap_decode_chunk's signature to the callback type ([2125503](https://github.com/claytercek/godot-hap-video/commit/21255036b7e817b44b1e62178aef5ae4e7f9828b))
* hook .mov loader into ResourceLoader ([04d044d](https://github.com/claytercek/godot-hap-video/commit/04d044d8ab93f5245beab37be66773e89cbcb427))
* make stock VideoStreamPlayer display Hap streams ([076eba1](https://github.com/claytercek/godot-hap-video/commit/076eba15562376567dc94c89aeec921724b1ea5a))
* **minimp4:** close remaining null-track derefs and O(n^2) hangs ([15ac7ad](https://github.com/claytercek/godot-hap-video/commit/15ac7adba6161550098174817db3b7fbb08b5955))
* **minimp4:** grow stts timestamp/duration arrays geometrically ([f36897e](https://github.com/claytercek/godot-hap-video/commit/f36897e1d89dd84077bf57e47ddab098fd3f06dc))
* **minimp4:** guard against chunk/sample arrays never allocated ([74b9d08](https://github.com/claytercek/godot-hap-video/commit/74b9d080f173501fc85b4dd06d101be628d1c805))
* **minimp4:** harden MP4D_open against malformed files ([e87ae74](https://github.com/claytercek/godot-hap-video/commit/e87ae74ee97eeea30dec69d00c249c5e21f5e8ec))
* **minimp4:** stop BOX_ctts spinning past its actual payload ([5965126](https://github.com/claytercek/godot-hap-video/commit/5965126346a7f35ee4c734b17cf15d323eab7975))
* **minimp4:** widen malloc size expressions before overflow can occur ([fc098ce](https://github.com/claytercek/godot-hap-video/commit/fc098ce569db9991ee9079a1e28d4c50f9c8f893))
* **test:** box opened flag so the handler write is seen ([ddcaae8](https://github.com/claytercek/godot-hap-video/commit/ddcaae86ecb938cfe8c28232ca88efee6dd078b9))
* **test:** real newlines and honest per-test status ([af8a00f](https://github.com/claytercek/godot-hap-video/commit/af8a00f9bd24c48364559290341e4fe9d19d7aa4))
* **tests:** make core test suite portable to MSVC/Windows ([df33d31](https://github.com/claytercek/godot-hap-video/commit/df33d313399a040949b081b0fdcb2e9a4ce3ad00))


### Refactoring

* **core:** dedup box walking, slim DemuxResult ([ee29f7c](https://github.com/claytercek/godot-hap-video/commit/ee29f7ca19cdde88569152eada0e4e70fd2f2563))
* **core:** fix code smells in demuxer ([acd0d35](https://github.com/claytercek/godot-hap-video/commit/acd0d35e76be85092596f51ac03796177fb198d9))
* **core:** remove dead code, simplify decoder retry ([64fa083](https://github.com/claytercek/godot-hap-video/commit/64fa0835d0d7ad57351a2a9751a0ff3dd6b9185d))
* **core:** share outer worker count constant ([b88bb0b](https://github.com/claytercek/godot-hap-video/commit/b88bb0b8dc7f3d2117f30be047c3a65870c8b125))
* **core:** wrap Demuxer's minimp4 context in unique_ptr ([22aad2c](https://github.com/claytercek/godot-hap-video/commit/22aad2c0820a3c4058291fa55f64a01f5af989f6))
* **godot:** dedupe HapPlayer's retarget bookkeeping, tidy repo ([fbce350](https://github.com/claytercek/godot-hap-video/commit/fbce3506ed56d9b3cb1c2c98e391846dab085ced))
* **godot:** delete unused HapTexture2D ([21a354d](https://github.com/claytercek/godot-hap-video/commit/21a354d92d85c7b40f42fe77e6c241c4d6153ab8))
* **godot:** reuse uniform sets, single shader source ([4c91bc8](https://github.com/claytercek/godot-hap-video/commit/4c91bc87ed0a94ce52f3ed4346749ef86048d523))
* **godot:** route _update through poll_ready ([725ae3a](https://github.com/claytercek/godot-hap-video/commit/725ae3ae0a370947ddafec5f0274ad0f59425907))


### CI

* trigger 0.1.0 release ([e6eb020](https://github.com/claytercek/godot-hap-video/commit/e6eb020324908d430997df97b477e790b8875f27))
