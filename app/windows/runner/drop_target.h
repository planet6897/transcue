#ifndef RUNNER_DROP_TARGET_H_
#define RUNNER_DROP_TARGET_H_

#include <ole2.h>

#include <functional>
#include <string>
#include <vector>

// 창 위에 끌어다 놓은 것을 받는다: 브라우저에서 끌어 온 링크(글)와 파일 경로.
// 무엇을 열지는 Dart(pickDropped)가 고른다.
class DropTarget : public IDropTarget {
 public:
  using Callback = std::function<void(const std::vector<std::string>&)>;

  explicit DropTarget(Callback callback);

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD key_state,
                                      POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL point,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD key_state,
                                 POINTL point, DWORD* effect) override;

 private:
  virtual ~DropTarget() = default;

  // 놓을 수 있으면 복사(없으면 링크) 표시, 아니면 금지 표시
  DWORD Effect(DWORD allowed) const;

  Callback callback_;
  ULONG ref_count_ = 1;
  bool acceptable_ = false;
};

#endif  // RUNNER_DROP_TARGET_H_
