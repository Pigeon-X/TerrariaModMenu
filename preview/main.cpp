//
// 桌面预览器：在 Windows 上直接跑菜单 UI，鼠标操作，用来快速打磨外观。
// 复用完全相同的 src/ui/menu.mm（用 /TP 当 C++ 编），数据是假的。
//
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <tchar.h>

#include <cstring>
#include <string>
#include <vector>

#include "imgui.h"
#include "imgui_impl_win32.h"
#include "imgui_impl_dx11.h"

#include "../src/ui/menu.hpp"
#include "../src/ui/ball_texture.hpp"

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

namespace {
ID3D11Device* g_device = nullptr;
ID3D11DeviceContext* g_ctx = nullptr;
IDXGISwapChain* g_swap = nullptr;
ID3D11RenderTargetView* g_rtv = nullptr;

bool create_rtv() {
    ID3D11Texture2D* back = nullptr;
    if (FAILED(g_swap->GetBuffer(0, IID_PPV_ARGS(&back)))) return false;
    g_device->CreateRenderTargetView(back, nullptr, &g_rtv);
    back->Release();
    return g_rtv != nullptr;
}

bool init_d3d(HWND hwnd) {
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = 0;
    sd.BufferDesc.Height = 0;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    const D3D_FEATURE_LEVEL want[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL got;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, want, 2, D3D11_SDK_VERSION,
        &sd, &g_swap, &g_device, &got, &g_ctx);
    if (FAILED(hr)) return false;
    return create_rtv();
}

// 把嵌入的球图标做成 DX11 纹理
void make_ball_texture() {
    const char* hex = ui::ball_texture_hex();
    const int size = ui::kBallTextureSize;
    const size_t n = strlen(hex) / 2;
    std::vector<unsigned char> px(n);
    auto hv = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
    };
    for (size_t i = 0; i < n; ++i) px[i] = (unsigned char)((hv(hex[i * 2]) << 4) | hv(hex[i * 2 + 1]));

    D3D11_TEXTURE2D_DESC td = {};
    td.Width = size;
    td.Height = size;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA srd = {};
    srd.pSysMem = px.data();
    srd.SysMemPitch = size * 4;
    ID3D11Texture2D* tex = nullptr;
    if (FAILED(g_device->CreateTexture2D(&td, &srd, &tex))) return;
    D3D11_SHADER_RESOURCE_VIEW_DESC sv = {};
    sv.Format = td.Format;
    sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    sv.Texture2D.MipLevels = 1;
    ID3D11ShaderResourceView* srv = nullptr;
    g_device->CreateShaderResourceView(tex, &sv, &srv);
    tex->Release();
    if (srv) ui::set_ball_texture((void*)srv);
}

LRESULT WINAPI wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp)) return true;
    switch (msg) {
        case WM_SIZE:
            if (g_device && wp != SIZE_MINIMIZED) {
                if (g_rtv) { g_rtv->Release(); g_rtv = nullptr; }
                g_swap->ResizeBuffers(0, LOWORD(lp), HIWORD(lp), DXGI_FORMAT_UNKNOWN, 0);
                create_rtv();
            }
            return 0;
        case WM_SYSCOMMAND:
            if ((wp & 0xfff0) == SC_KEYMENU) return 0;
            break;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}
}  // namespace

int main(int, char**) {
    WNDCLASSEX wc = {sizeof(wc), CS_CLASSDC, wnd_proc, 0, 0, GetModuleHandle(nullptr),
                     nullptr, nullptr, nullptr, nullptr, "ModMenuPreview", nullptr};
    RegisterClassEx(&wc);
    HWND hwnd = CreateWindow(wc.lpszClassName, "Terraria ModMenu Preview (desktop)",
                             WS_OVERLAPPEDWINDOW, 80, 60, 1280, 760,
                             nullptr, nullptr, wc.hInstance, nullptr);
    if (!init_d3d(hwnd)) { MessageBox(nullptr, "D3D11 init failed", "Error", MB_OK); return 1; }
    ShowWindow(hwnd, SW_SHOWDEFAULT);
    UpdateWindow(hwnd);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr;
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(1.0f);
    ImGui_ImplWin32_Init(hwnd);
    ImGui_ImplDX11_Init(g_device, g_ctx);
    make_ball_texture();

    // 造几条日志，方便看日志页的排版
    ui::log_line("预览器已启动 —— 这里的数据都是假的，只用来调 UI");
    ui::log_line("[示例Mod] 找到类：Terraria.Main");
    ui::log_line("Mod 已加载：示例Mod v1.0");
    ui::log_line("Mod 扫描完成：发现 3 个，成功加载 2 个");
    ui::set_visible(false);           // 和游戏里一样，先显示球

    bool running = true;
    while (running) {
        MSG msg;
        while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
            if (msg.message == WM_QUIT) running = false;
        }
        if (!running) break;

        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        ui::draw();
        ImGui::Render();

        const float clear[4] = {0.10f, 0.16f, 0.26f, 1.0f};   // 假装游戏画面
        g_ctx->OMSetRenderTargets(1, &g_rtv, nullptr);
        g_ctx->ClearRenderTargetView(g_rtv, clear);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        g_swap->Present(1, 0);
    }
    return 0;
}
