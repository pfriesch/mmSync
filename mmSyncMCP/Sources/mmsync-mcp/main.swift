// MCP server for MoneyMoney over stdio. The same server ships inside the app as `mmSync --mcp`.
//
//   swift build -c release --package-path mmSyncMCP
//   claude mcp add moneymoney -- "$PWD/mmSyncMCP/.build/release/mmsync-mcp"
//
// MoneyMoney must be running and unlocked. On first use macOS asks to allow
// controlling MoneyMoney (System Settings → Privacy & Security → Automation).

import MoneyMoneyMCP

MoneyMoney.serve()
