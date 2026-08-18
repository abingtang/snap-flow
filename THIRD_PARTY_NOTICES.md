# Third-Party Notices

This file lists third-party materials bundled with SnapFlow. SnapFlow source
code is licensed under the MIT License. The items below keep their own rights
and terms.

## Service brand icons

The app ships local copies of third-party service marks so users can recognize
OCR and translation providers in Settings. These marks are trademarks of their
respective owners. Inclusion does **not** imply affiliation, sponsorship, or
endorsement. The links below point to official brand or service pages for
attribution; they are not necessarily direct image-download URLs.

| Asset | Official reference | Owner / notes |
|-------|--------------------|----------------|
| `OCRIconBaidu` | https://home.baidu.com/media_resource/show_detail/res_id/2/tab_id/1 | Baidu |
| `OCRIconGoogle` | https://www.google.com/images/branding/googleg/2x/googleg_standard_color_128dp.png | Google |
| `OCRIconTencent` | https://cloud.tencent.com/product/ocr | Tencent Cloud |
| `OCRIconYoudao` | https://ai.youdao.com/DOCSIRMA/html/ocr/api/tyocr/index.html | NetEase Youdao |
| `OCRIconVolcengine` | https://www.volcengine.com/product/OCR | Volcengine |
| `TranslationIconBaidu` | https://home.baidu.com/media_resource/show_detail/res_id/2/tab_id/1 | Baidu |
| `TranslationIconYoudao` | https://www.youdao.com/ | NetEase Youdao |
| `TranslationIconTencent` | https://www.tencent.com/newsroom/media-resources/ | Tencent |
| `TranslationIconCaiyun` | https://fanyi.caiyunapp.com/ | Caiyun |
| `TranslationIconGoogle` | https://about.google/intl/us_en/brand-resource-center/ | Google |
| `TranslationIconDeepl` | https://www.deepl.com/press | DeepL |
| `TranslationIconAliyun` | https://design.aliyun.com/ | Alibaba Cloud |
| `TranslationIconNiutrans` | https://niutrans.com/ | NiuTrans |
| `TranslationIconVolcengine` | https://www.volcengine.com/about | Volcengine |
| `TranslationIconMicrosoft` | https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks | Microsoft |
| `TranslationIconAmazon` | https://affiliate-program.amazon.com/help/operating/amazonmarks/ | Amazon |

Other translation icons in `macos/SnapFlow/Resources/Assets.xcassets/`
(OpenAI, OpenRouter, Ollama, Groq, Grok, DeepSeek, Kimi, Qwen, SiliconFlow,
Zhipu, LM Studio, and similar) are local identification artwork for those
services. The corresponding names and logos remain the property of their
owners.

Vision OCR and the custom-service entries use SF Symbols provided by Apple.
Those symbols are not redistributed as separate image files.

## System frameworks

SnapFlow links to Apple platform frameworks, including SwiftUI, AppKit,
ScreenCaptureKit, Vision, and Translation. Those frameworks are licensed by
Apple and are not part of this repository.

## Optional packaging tools

The release script can call [create-dmg](https://github.com/create-dmg/create-dmg)
if it is installed locally. That tool is not vendored here.

## Cloud APIs

Optional OCR and translation providers are called only when the user supplies
their own credentials in Settings. This repository does not include API keys,
and those services are governed by their own terms.
