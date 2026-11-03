# sdv — 在 StatDataViewer 中打开 R 对象

[English](README.md)

RStudio 插件：用快捷键、Addins 菜单、命令面板或 `View()`，把当前 R 会话里的对象直接发到桌面应用 **StatDataViewer** 中查看。数据框和矩阵显示为表，函数显示为代码，列表显示为树形表，模型和其他对象显示为文本，整个环境显示为对象清单。

## 安装

```r
install.packages("sdv", repos = c("https://sashelper.r-universe.dev",
                                  "https://cloud.r-project.org"))
```

也可以从 GitHub 安装开发版：

```r
# install.packages("pak")
pak::pak("sashelper/sdv")
```

另外需要在 macOS 或 Windows 上装好 StatDataViewer 本身。

## 使用

| 方式 | 说明 |
|---|---|
| 快捷键 **⌘⇧V**（Cmd+Shift+V；Windows 上是 Ctrl+Shift+V），发送一个对象 | 先运行一次 `sdv::sdv_install_shortcut()`，然后重启 RStudio。想换别的键：`sdv_install_shortcut("Cmd+Shift+K")` |
| **⌥⌘⇧V**（Cmd+Alt+Shift+V；Windows 上是 Ctrl+Alt+Shift+V），列出整个全局环境 | 先运行一次 `sdv::sdv_install_shortcut(binding = "sdv_addin_env")`，然后重启 RStudio |
| Addins 菜单 / 命令面板（⇧⌘P） | 搜索 “StatDataViewer”：发送一个对象、列出全局环境，或弹出输入框输入对象名 / 表达式 |
| `View(x)` / 在 Environment 面板里点对象名 | 运行 `sdv::sdv_use_as_viewer(TRUE)` 开启，用 `FALSE` 恢复 |
| 控制台 | `sdv::sdv_view(x)` 发送一个对象，`sdv::sdv_view_env()` 列出全局环境；先 `library(sdv)` 就不用写 `sdv::` |

所有函数都以 `sdv_` 开头，所以 `library(sdv)` 之后不会和其他包的函数重名。

**“Open in StatDataViewer”** 这个 addin 按以下顺序决定要发送的对象：

1. **有选中的代码**（编辑器或控制台都行）：在全局环境里求值，把结果发送过去。例如选中 `head(mtcars, 3)`，或者一整段管道代码。
2. **没有选中**：取光标所在的对象名，支持 `df`、`df$col`、`obj@slot`、`pkg::obj` 和 `` `带空格的名字` `` 这些写法。光标停在 `df$col` 的 `df` 上时发送 `df`，停在 `col` 上时发送 `df$col`。
3. **以上都取不到，或者求值出错**：弹出输入框，让你输入对象名或表达式。

## 任何对象

不只是数据框，每种对象都能打开（见下面的类型表）：函数显示为 R 代码，列表显示为树形表，模型和 S4 对象显示为文本。快捷键和 Addins 菜单接受任何对象；`sdv_use_as_viewer(TRUE)` 开启后 `View()` 也一样，想让函数、列表、模型留在 RStudio 自带的查看器里，传 `types = "tabular"`。

RStudio 没有开放给插件往右键菜单里加菜单项的接口，所以这里用“接管 `View()`”来代替右键菜单：在 Environment 面板里点对象名，RStudio 执行的就是 `View()`。但 RStudio 只把 **Data** 行（数据框、矩阵、列表、环境、S4 对象、模型）和 **Function** 行的名字做成可点击的；**Values** 行（向量、因子、单个值）在 RStudio 里根本没有可点的地方，这类对象请用快捷键、Addins 菜单或 `sdv_view(x)` 发送。要让每个会话都自动开启接管，把 `sdv_use_as_viewer()` 打印出的那段代码加到 `~/.Rprofile` 里。

## 整个环境

`sdv_view_env()`、**Open Global Environment in StatDataViewer** 这个 addin 和它的 ⌥⌘⇧V 快捷键会打开全局环境的对象清单，一个对象一行：名字、kind（Data / Values / Functions，和 RStudio 的 Environment 面板一致）、class、维度、大小和一行描述。可以在 StatDataViewer 里排序、过滤；环境变了再发一次。任何环境都可以：`sdv_view_env(environment(lm))`。

## 支持的类型

| R 对象 | 在 StatDataViewer 中显示为 |
|---|---|
| data.frame / tibble / data.table / sf | 数据表。非默认的行名会变成 `row_names` 列 |
| matrix、二维 table / xtabs | 宽表 |
| 三维及以上的 array / table | 长表 |
| ts / mts、zoo / xts | 数据表：`time`、`cycle` 列，或 `index` 列，加上数值列 |
| 原子向量、factor、Date | 一列 `value`；有名字的向量还有一列 `name` |
| 列表 | 各元素等长时显示为数据表；否则展开成树形表，列为 path / class / type / size / preview |
| environment | 对象清单：名字、kind、class、维度、大小、描述 |
| function / formula / call | `.R` 文本 |
| lm / glm | `summary()` 输出的文本 |
| S4、R6、htest 等其他对象 | `print()` 和 `str()` 输出的文本 |

StatDataViewer 读 `.rds` 用的是 librdata，能显示的类型有限。所以每一列在发送前都会转换成它能正确显示的形式：

- **factor**：转成标签文字。
- **POSIXct / POSIXlt**：按原时区的墙钟时间显示（Viewer 固定按 UTC 显示时间，这里预先做了换算），时区写进列的 label。
- **Date**：统一改成 double 存储。未修复的 StatDataViewer 版本会读错整数存储的日期（比如新版 R 里 `seq()` 生成的）。
- **list 列、complex、raw**：转成摘要文本。
- **difftime**：转成数值，单位写进 label。
- **hms**：转成 `HH:MM:SS` 格式的文本。
- **integer64**：转成数值；超过 2^53 时转成字符串。
- **haven_labelled**：保留数值编码，另加一列 `*_lbl` 放标签文字。
- **data.frame 列 / 矩阵列**：展开成多列。

## 选项

| 选项 | 作用 |
|---|---|
| `sdv.app` | 指定要用的 `StatDataViewer.app` 路径（macOS）。本机有多份构建时用它来选。 |
| `sdv.exe` | 指定 `StatDataViewer.exe` 路径（Windows） |
| `sdv.dir` | 临时文件目录，默认是 `tempdir()/sdv` |
| `sdv.view_types` | `"all"`（默认）或 `"tabular"`，决定 `View()` 接管的范围 |
| `sdv.max_text_lines` | 文本输出的最大行数 |
| `sdv.list_max_rows` | 列表展开成树形表时的最大行数 |

## 工作原理

1. `sdv_prepare()` 把对象转换成干净的 data.frame 或文本。
2. 转换结果写到一个唯一的临时目录里（`saveRDS(version = 2)`，不压缩）。每次都换目录，所以 Viewer 不会弹 “Reload Dataset?”；文件名就是变量名，也就是标签页标题。
3. **macOS**：`open -b com.statdataviewer <file>`。App 已在运行时直接交给它（`QFileOpenEvent`），没运行时先启动。
4. **Windows**：执行 `StatDataViewer.exe <file>`，由 App 的单实例机制转发给已在运行的实例。这部分还没有实测。

## 扩展

可以为自己的类写 S3 方法，返回 data.frame（显示为表）、字符向量（显示为文本）或 `NULL`：

```r
sdv_prepare.myclass <- function(x, name = "object", ...) as.data.frame(x$data)
```

## 开发

```sh
Rscript -e 'testthat::test_local()'
```

`test-librdata-compat.R` 是可选测试：本机有 StatDataViewer 源码时（用 `SDV_SOURCE_DIR` 指定位置），它会开着 AddressSanitizer 编译一个小 probe，调用 Viewer 自己的 R 读取器，逐格核对每种输出在 Viewer 里实际显示成什么。没有源码的环境（包括 CI）会自动跳过这个测试。

发布流程见 [RELEASING.md](RELEASING.md)。

## 许可证

MIT
