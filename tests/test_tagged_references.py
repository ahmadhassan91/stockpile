from stockpile.tagged_references import TaggedReferenceSpec


def test_tagged_reference_spec_uses_tag_face_size_for_corner_based_calibration():
    spec = TaggedReferenceSpec(
        tag_id=12,
        family="tag36h11",
        label="North Pole Marker",
        tag_size_m=0.18,
        reference_height_m=1.20,
        reference_width_m=0.45,
    )

    assert spec.calibration_tag_size_m == 0.18
    assert spec.scale_dimension_m == 1.20
    assert spec.has_extended_reference_geometry is True


def test_tagged_reference_spec_without_extra_geometry_uses_tag_size_everywhere():
    spec = TaggedReferenceSpec(
        tag_id=7,
        family="tag25h9",
        tag_size_m=0.24,
    )

    assert spec.calibration_tag_size_m == 0.24
    assert spec.scale_dimension_m == 0.24
    assert spec.has_extended_reference_geometry is False
