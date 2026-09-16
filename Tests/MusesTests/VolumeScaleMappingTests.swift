import Testing
@testable import Muses

struct VolumeScaleMappingTests {
    @Test func pointerMatchesEntireVisibleScale() {
        for width in [80.0, 173.0, 304.0] {
            #expect(VolumeScaleMapping.volume(at: 0, width: width) == 0)
            #expect(VolumeScaleMapping.volume(at: width * 0.25, width: width) == 0.25)
            #expect(VolumeScaleMapping.volume(at: width / 2, width: width) == 0.5)
            #expect(VolumeScaleMapping.volume(at: width, width: width) == 1)
            #expect(VolumeScaleMapping.volume(at: -20, width: width) == 0)
            #expect(VolumeScaleMapping.volume(at: width + 20, width: width) == 1)
        }
        #expect(VolumeScaleMapping.volume(at: .nan, width: 100) == 0)
        #expect(VolumeScaleMapping.volume(at: 10, width: 0) == 0)
    }
}
