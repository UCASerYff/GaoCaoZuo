"""Argos v1.9 release archives and the four files used by the local engine."""

from gaocaozuo.translation import ModelFile, ModelPack


PACKS = (
    ModelPack("zh", "en", "1.9", 74_481_402, "62e7af5a3a48b530e47b7b3e5c78c2de79073ecd815750d2bf3ab35b4a67da2d", (
        ModelFile("sentencepiece.model", 804_374, "72600ea476b3e3b76763919c3a30ef5104d9b473b19567d45251f56034264f54"),
        ModelFile("model/config.json", 196, "b28e3136fc7a103e29585c10c8124849fb01d649531f58e00cbe240111560cd7"),
        ModelFile("model/model.bin", 82_713_318, "edd8c8a6863d36959613ff291074627a1635fab2f51b872ef437e924d238921a"),
        ModelFile("model/shared_vocabulary.json", 1_368_422, "c980413009e8041fc42c81730ad4b72ab6cb1313b3b89b1ced261fe5e177b024"),
    )),
    ModelPack("en", "zh", "1.9", 70_743_021, "433e7c4f034d87fbe2353161e05f18646d7999452f801a4e1f0378522b9850ab", (
        ModelFile("sentencepiece.model", 806_370, "872224b85a11edc9d769a94949fd387b67ea85b50708db9f91f32f5b497a9af3"),
        ModelFile("model/config.json", 216, "3a8660f12559a223969532ff191e5e6f50d4ff24164517edbd6a5090dc5144c6"),
        ModelFile("model/model.bin", 82_713_318, "1a039114d9456b6528fabb65b455b6f156319634a0f984b1f6018f7737d67598"),
        ModelFile("model/shared_vocabulary.json", 1_367_577, "c0b6e24705ec0489d5b810de365959c1013aecd644cfeca161b54ea1df6a7dc0"),
    )),
)
