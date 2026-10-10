--[[
  示例 Mod
  ---------
  把这个文件夹整个拷到 App 沙盒的 Documents/Mods/ 下面，
  然后在游戏里打开菜单 -> Mods 页 -> 「重新扫描」。
  加载成功后，菜单里会多出一个「示例Mod」标签页。
--]]

local Main = nil
local clickCount = 0
local frameCount = 0
local coroutineTicks = 0

function onLoad()
    Log("示例Mod 载入，MOD_DIR = " .. tostring(MOD_DIR))
    Log("Lua 版本：" .. LUA_VERSION)

    -- 按名字反射拿游戏类型（不依赖任何偏移）
    Main = Native.Class("Terraria", "Main")
    if Main then
        Log("找到类：" .. Main:fullName())
    else
        Log("没找到 Terraria.Main —— 检查 IL2CPP 是否就绪")
    end

    -- 协程演示
    Runtime.Spawn(function()
        for i = 1, 3 do
            Log("协程第 " .. i .. " 次（间隔 2 秒）")
            Runtime.Wait(2)
        end
        Log("协程跑完了")
    end)

    -- 自己的 UI 面板
    Native.UI(function()
        UI.Text("示例Mod 面板")
        UI.Separator()

        local v = UI.SliderInt("数值", clickCount, 0, 100)
        clickCount = v
        if UI.Button("点我 +1") then
            clickCount = clickCount + 1
        end
        UI.SameLine()
        UI.Text("当前 = " .. clickCount)

        UI.Separator()
        UI.Text("onUpdate 次数：" .. frameCount)
        UI.Text("协程 tick：" .. coroutineTicks)
        if Main then
            UI.TextColored("IL2CPP 反射可用", 0.4, 1.0, 0.4)
        else
            UI.TextColored("IL2CPP 反射不可用", 1.0, 0.4, 0.4)
        end
    end)
end

function onUpdate()
    frameCount = frameCount + 1
    coroutineTicks = coroutineTicks + 1
end

function onUnload()
    Log("示例Mod 卸载")
end
