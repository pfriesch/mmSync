// MCP server for MoneyMoney over stdio.
//
//   swift build -c release --package-path mmSyncMCP
//   claude mcp add moneymoney -- "$PWD/mmSyncMCP/.build/release/mmsync-mcp"
//
// MoneyMoney must be running and unlocked. On first use macOS asks to allow
// controlling MoneyMoney (System Settings → Privacy & Security → Automation).

import Foundation
import MoneyMoneyMCP

/// White "M" on a green rounded square.
let logo = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">\
<rect width="64" height="64" rx="14" fill="#1F7A4D"/>\
<path d="M16 48V16h7l9 14 9-14h7v32h-7V28l-9 13-9-13v20z" fill="#fff"/>\
</svg>
"""

MCPServer(
    name: "mmsync-mcp",
    version: "0.1.0",
    tools: MoneyMoney().tools,
    icons: [[
        "src": "data:image/svg+xml;base64," + Data(logo.utf8).base64EncodedString(),
        "mimeType": "image/svg+xml",
        "sizes": ["any"],
    ]]
).run()
