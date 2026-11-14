#include "drop_target.h"

#include <shellapi.h>

#include <utility>

#include "utils.h"

namespace {

FORMATETC Format(CLIPFORMAT format) {
  return {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

bool Has(IDataObject* data, CLIPFORMAT format) {
  FORMATETC f = Format(format);
  return data->QueryGetData(&f) == S_OK;
}

// 끌어 온 것: 파일은 경로, 링크는 글(주소)로 온다
std::vector<std::string> Read(IDataObject* data) {
  std::vector<std::string> items;
  STGMEDIUM medium = {};

  FORMATETC files = Format(CF_HDROP);
  if (data->GetData(&files, &medium) == S_OK) {
    HDROP drop = static_cast<HDROP>(medium.hGlobal);
    UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
      std::wstring path(length + 1, L'\0');
      ::DragQueryFileW(drop, i, path.data(), length + 1);
      items.push_back(Utf8FromUtf16(path.c_str()));
    }
    ::ReleaseStgMedium(&medium);
  }

  FORMATETC text = Format(CF_UNICODETEXT);
  if (data->GetData(&text, &medium) == S_OK) {
    const wchar_t* value =
        static_cast<const wchar_t*>(::GlobalLock(medium.hGlobal));
    if (value != nullptr) {
      items.push_back(Utf8FromUtf16(value));
      ::GlobalUnlock(medium.hGlobal);
    }
    ::ReleaseStgMedium(&medium);
  }
  return items;
}

}  // namespace

DropTarget::DropTarget(Callback callback) : callback_(std::move(callback)) {}

HRESULT DropTarget::QueryInterface(REFIID riid, void** object) {
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

ULONG DropTarget::AddRef() { return ++ref_count_; }

ULONG DropTarget::Release() {
  ULONG count = --ref_count_;
  if (count == 0) {
    delete this;
  }
  return count;
}

DWORD DropTarget::Effect(DWORD allowed) const {
  if (!acceptable_) {
    return DROPEFFECT_NONE;
  }
  if (allowed & DROPEFFECT_COPY) {
    return DROPEFFECT_COPY;
  }
  return allowed & DROPEFFECT_LINK;
}

HRESULT DropTarget::DragEnter(IDataObject* data, DWORD, POINTL,
                              DWORD* effect) {
  acceptable_ = Has(data, CF_HDROP) || Has(data, CF_UNICODETEXT);
  *effect = Effect(*effect);
  return S_OK;
}

HRESULT DropTarget::DragOver(DWORD, POINTL, DWORD* effect) {
  *effect = Effect(*effect);
  return S_OK;
}

HRESULT DropTarget::DragLeave() {
  acceptable_ = false;
  return S_OK;
}

HRESULT DropTarget::Drop(IDataObject* data, DWORD, POINTL, DWORD* effect) {
  *effect = Effect(*effect);
  acceptable_ = false;
  std::vector<std::string> items = Read(data);
  if (items.empty()) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  callback_(items);
  return S_OK;
}
