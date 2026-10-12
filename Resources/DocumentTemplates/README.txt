搞操作原生空白文档资源

DOCX/XLSX/PPTX：由 Scripts/generate_document_templates.py 使用开源文档库从空白对象创建，作者/最后修改者为空；生成后已用对应库重新打开。
RTF/XML：本项目原创最小有效空白文档。
PSD：按 Adobe 公开 PSD 文件格式规格直接生成，512×512、8-bit RGB 白色画布；不是 PNG 改后缀。规格 https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/ 。系统 ImageIO 解码验收。
Pages/Numbers/Keynote：2026-10-12 在本机 Apple 原生应用中创建空白文档（Keynote 移除全部占位对象），保存并关闭后重新打开通过。不是从超级右键或其他应用包复制模板。

Tests/TemplateAssetTests.py 验证九种原生文档结构、ZIP/内部XML、PSD头与完整像素数据，并解压 iWork IWA 元数据检查已知本地账号、个人绝对路径及常见私人邮箱标记。此检查没有读取私人文档。

仍未内置 WPS .wps/.et/.dps、Illustrator .ai 原生模板。可导入用户自己拥有的有效文档作为模板；不能把 Office、PDF、PNG 或空文件改后缀当成这些格式。不得因此宣称这些预设已完全替代。
