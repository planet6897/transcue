#include "system_brightness.h"

#include <comdef.h>
#include <highlevelmonitorconfigurationapi.h>
#include <physicalmonitorenumerationapi.h>
#include <wbemidl.h>

#include <vector>

namespace system_brightness {
namespace {

// ---- 외부 모니터: DDC/CI ----

struct PhysicalMonitors {
  std::vector<PHYSICAL_MONITOR> list;
  ~PhysicalMonitors() {
    if (!list.empty()) {
      ::DestroyPhysicalMonitors(static_cast<DWORD>(list.size()), list.data());
    }
  }
};

bool OpenMonitors(HWND window, PhysicalMonitors& out) {
  HMONITOR mon = ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  DWORD n = 0;
  if (!::GetNumberOfPhysicalMonitorsFromHMONITOR(mon, &n) || n == 0) {
    return false;
  }
  out.list.resize(n);
  if (!::GetPhysicalMonitorsFromHMONITOR(mon, n, out.list.data())) {
    out.list.clear();
    return false;
  }
  return true;
}

std::optional<double> DdcGet(HWND window) {
  PhysicalMonitors mons;
  if (!OpenMonitors(window, mons)) return std::nullopt;
  for (auto& m : mons.list) {
    DWORD lo = 0, cur = 0, hi = 0;
    if (::GetMonitorBrightness(m.hPhysicalMonitor, &lo, &cur, &hi) &&
        hi > lo) {
      return static_cast<double>(cur - lo) / (hi - lo);
    }
  }
  return std::nullopt;
}

std::optional<double> DdcSet(HWND window, double level) {
  PhysicalMonitors mons;
  if (!OpenMonitors(window, mons)) return std::nullopt;
  std::optional<double> done;
  for (auto& m : mons.list) {
    DWORD lo = 0, cur = 0, hi = 0;
    if (!::GetMonitorBrightness(m.hPhysicalMonitor, &lo, &cur, &hi) ||
        hi <= lo) {
      continue;
    }
    const DWORD want = lo + static_cast<DWORD>(level * (hi - lo) + 0.5);
    if (::SetMonitorBrightness(m.hPhysicalMonitor, want)) {
      done = static_cast<double>(want - lo) / (hi - lo);
    }
  }
  return done;
}

// ---- 노트북 내장 화면: WMI (root\WMI WmiMonitorBrightness) ----

IWbemServices* ConnectWmi() {
  IWbemLocator* locator = nullptr;
  if (FAILED(::CoCreateInstance(CLSID_WbemLocator, nullptr,
                                CLSCTX_INPROC_SERVER, IID_IWbemLocator,
                                reinterpret_cast<void**>(&locator)))) {
    return nullptr;
  }
  IWbemServices* svc = nullptr;
  HRESULT hr = locator->ConnectServer(_bstr_t(L"ROOT\\WMI"), nullptr, nullptr,
                                      nullptr, 0, nullptr, nullptr, &svc);
  locator->Release();
  if (FAILED(hr)) return nullptr;
  ::CoSetProxyBlanket(svc, RPC_C_AUTHN_WINNT, RPC_C_AUTHZ_NONE, nullptr,
                      RPC_C_AUTHN_LEVEL_CALL, RPC_C_IMP_LEVEL_IMPERSONATE,
                      nullptr, EOAC_NONE);
  return svc;
}

// 쿼리 결과의 첫 개체 (없으면 nullptr)
IWbemClassObject* First(IWbemServices* svc, const wchar_t* query) {
  IEnumWbemClassObject* e = nullptr;
  if (FAILED(svc->ExecQuery(
          _bstr_t(L"WQL"), _bstr_t(query),
          WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY, nullptr,
          &e))) {
    return nullptr;
  }
  IWbemClassObject* obj = nullptr;
  ULONG got = 0;
  e->Next(3000, 1, &obj, &got);
  e->Release();
  return got == 1 ? obj : nullptr;
}

std::optional<double> WmiGet() {
  IWbemServices* svc = ConnectWmi();
  if (svc == nullptr) return std::nullopt;
  std::optional<double> out;
  if (IWbemClassObject* o =
          First(svc, L"SELECT CurrentBrightness FROM WmiMonitorBrightness")) {
    VARIANT v;
    ::VariantInit(&v);
    if (SUCCEEDED(o->Get(L"CurrentBrightness", 0, &v, nullptr, nullptr))) {
      out = (v.vt == VT_UI1 ? v.bVal : v.uintVal) / 100.0;
    }
    ::VariantClear(&v);
    o->Release();
  }
  svc->Release();
  return out;
}

std::optional<double> WmiSet(double level) {
  IWbemServices* svc = ConnectWmi();
  if (svc == nullptr) return std::nullopt;
  std::optional<double> out;
  IWbemClassObject* inst =
      First(svc, L"SELECT * FROM WmiMonitorBrightnessMethods");
  IWbemClassObject* cls = nullptr;
  IWbemClassObject* inDef = nullptr;
  IWbemClassObject* in = nullptr;
  if (inst != nullptr &&
      SUCCEEDED(svc->GetObject(_bstr_t(L"WmiMonitorBrightnessMethods"), 0,
                               nullptr, &cls, nullptr)) &&
      SUCCEEDED(cls->GetMethod(L"WmiSetBrightness", 0, &inDef, nullptr)) &&
      SUCCEEDED(inDef->SpawnInstance(0, &in))) {
    const int pct = static_cast<int>(level * 100 + 0.5);
    VARIANT timeout, bright;
    ::VariantInit(&timeout);
    ::VariantInit(&bright);
    timeout.vt = VT_I4;
    timeout.lVal = 0;
    bright.vt = VT_UI1;
    bright.bVal = static_cast<BYTE>(pct);
    in->Put(L"Timeout", 0, &timeout, 0);
    in->Put(L"Brightness", 0, &bright, 0);
    VARIANT path;
    ::VariantInit(&path);
    if (SUCCEEDED(inst->Get(L"__PATH", 0, &path, nullptr, nullptr)) &&
        SUCCEEDED(svc->ExecMethod(path.bstrVal, _bstr_t(L"WmiSetBrightness"),
                                  0, nullptr, in, nullptr, nullptr))) {
      out = pct / 100.0;
    }
    ::VariantClear(&path);
  }
  if (in != nullptr) in->Release();
  if (inDef != nullptr) inDef->Release();
  if (cls != nullptr) cls->Release();
  if (inst != nullptr) inst->Release();
  svc->Release();
  return out;
}

}  // namespace

// WMI는 노트북 내장 화면만 바꾼다. 창이 다른(외부) 모니터에 있는데 내장 화면이
// 어두워지면 안 되므로, 창이 주 모니터에 있을 때만 쓴다 (노트북은 보통 내장 화면이 주 모니터).
bool OnPrimaryMonitor(HWND window) {
  MONITORINFO info{sizeof(info)};
  return ::GetMonitorInfo(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                          &info) &&
         (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
}

std::optional<double> Get(HWND window) {
  if (auto v = DdcGet(window)) return v;
  if (!OnPrimaryMonitor(window)) return std::nullopt;
  return WmiGet();
}

std::optional<double> Set(HWND window, double level) {
  if (level < 0) level = 0;
  if (level > 1) level = 1;
  if (auto v = DdcSet(window, level)) return v;
  if (!OnPrimaryMonitor(window)) return std::nullopt;
  return WmiSet(level);
}

}  // namespace system_brightness
