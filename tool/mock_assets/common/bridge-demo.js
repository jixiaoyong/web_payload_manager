(function () {
  var bridgeReadyBound = false;
  function whenBridgeReady(callback) {
    function safeRun() {
      if (bridgeReadyBound) return;
      bridgeReadyBound = true;
      callback();
    }

    if (window.__BRIDGE_META__ && window.__BRIDGE_READY_DISPATCHED__) {
      safeRun();
      return;
    }
    window.addEventListener("payloadBridgeReady", safeRun);
    window.addEventListener("flutterInAppWebViewPlatformReady", function () {
      if (window.__BRIDGE_READY_DISPATCHED__) safeRun();
    });
    if (window.__BRIDGE_READY_DISPATCHED__) {
      safeRun();
    }
  }

  function bridgeCall(channel, data) {
    return new Promise(function (resolve, reject) {
      var handler = window[channel];
      if (!handler || typeof handler.postMessage !== "function") {
        reject(new Error("Channel not ready: " + channel));
        return;
      }
      var callbackId =
        "cb_" + Date.now() + "_" + Math.random().toString(36).slice(2);
      window.__webviewChannelCallbacks = window.__webviewChannelCallbacks || {};
      var timeout = setTimeout(function () {
        delete window.__webviewChannelCallbacks[callbackId];
        reject(new Error("Bridge timeout: " + channel));
      }, 35000);
      window.__webviewChannelCallbacks[callbackId] = function (raw) {
        clearTimeout(timeout);
        delete window.__webviewChannelCallbacks[callbackId];
        try {
          var parsed = typeof raw === "string" ? JSON.parse(raw) : raw;
          if (typeof parsed === "string") {
            parsed = JSON.parse(parsed);
          }
          if (parsed && parsed.__isBridgeError) {
            reject(new Error(parsed.msg || "Bridge error"));
            return;
          }
          resolve(parsed);
        } catch (error) {
          reject(error);
        }
      };
      try {
        handler.postMessage(
          JSON.stringify({ callbackId: callbackId, data: data || {} })
        );
      } catch (error) {
        clearTimeout(timeout);
        delete window.__webviewChannelCallbacks[callbackId];
        reject(error);
      }
    });
  }

  window.__AppEventBus = window.__AppEventBus || {
    handlers: [],
    on: function (fn) {
      this.handlers.push(fn);
    },
    emit: function (type, data) {
      this.handlers.forEach(function (fn) {
        try {
          fn(type, data);
        } catch (_) {}
      });
    },
  };

  function setOutput(text) {
    var el = document.getElementById("bridge-output");
    if (el) {
      el.textContent = text;
    }
  }

  // ============ SPA 路由模拟与返回事件协商协议 ============
  var currentRoute = "/";

  function goToSubView() {
    currentRoute = "/sub-detail";
    var mainEl = document.getElementById("view-main");
    var subEl = document.getElementById("view-sub");
    if (mainEl) mainEl.style.display = "none";
    if (subEl) subEl.style.display = "block";
    setOutput("已进入 H5 二级路由 [/sub-detail]。请尝试按下物理返回键！");
  }

  function goToMainView() {
    currentRoute = "/";
    var mainEl = document.getElementById("view-main");
    var subEl = document.getElementById("view-sub");
    if (mainEl) mainEl.style.display = "block";
    if (subEl) subEl.style.display = "none";
    setOutput("已退回 H5 一级页面 [/]。再次按返回键将退出原生容器。");
  }

  // 混合开发核心：注册双向返回协商函数
  // 原生在 Android 返回键或侧滑时会先执行此函数
  window.__tryGoBack = function () {
    if (currentRoute !== "/") {
      goToMainView();
      return true; // 告知 Flutter: H5 已消费回退事件，不要 Pop 原生页面
    }
    return false; // 告知 Flutter: 已在根路径，允许 Pop 原生页面
  };

  function updateOrderCardStatus(statusText, isSuccess) {
    var statusEl = document.getElementById("order-status");
    if (!statusEl) return;
    if (isSuccess) {
      statusEl.className = "order-status paid";
      statusEl.textContent = "订单状态：" + statusText;
    } else {
      statusEl.className = "order-status";
      statusEl.textContent = "订单状态：" + statusText;
    }
  }

  function bindDemoButtons() {
    var echoBtn = document.getElementById("btn-echo");
    var infoBtn = document.getElementById("btn-info");
    var toastBtn = document.getElementById("btn-toast");
    var modalBtn = document.getElementById("btn-modal");
    var enterSubBtn = document.getElementById("btn-enter-sub");
    var backMainBtn = document.getElementById("btn-back-main");
    var subActionBtn = document.getElementById("btn-sub-action");

    var payAppleBtn = document.getElementById("btn-pay-apple");
    var payAlipayBtn = document.getElementById("btn-pay-alipay");
    var payWechatBtn = document.getElementById("btn-pay-wechat");

    if (echoBtn) {
      echoBtn.addEventListener("click", function () {
        bridgeCall("DemoEcho", { message: "hello from H5", timestamp: Date.now() })
          .then(function (result) {
            setOutput("DemoEcho 成功: " + JSON.stringify(result));
          })
          .catch(function (error) {
            setOutput("DemoEcho 失败: " + error);
          });
      });
    }

    if (infoBtn) {
      infoBtn.addEventListener("click", function () {
        bridgeCall("DemoHostInfo")
          .then(function (result) {
            setOutput("DemoHostInfo 成功: " + JSON.stringify(result));
          })
          .catch(function (error) {
            setOutput("DemoHostInfo 失败: " + error);
          });
      });
    }

    if (toastBtn) {
      toastBtn.addEventListener("click", function () {
        bridgeCall("DemoToast", { message: "来自 H5 的原生 Toast 提示" })
          .then(function () {
            setOutput("DemoToast: 触发成功");
          })
          .catch(function (error) {
            setOutput("DemoToast 失败: " + error);
          });
      });
    }

    var isModalBusy = false;
    if (modalBtn) {
      modalBtn.addEventListener("click", function () {
        if (isModalBusy) return;
        isModalBusy = true;
        setOutput("正在唤起原生弹窗...");
        bridgeCall("DemoNativeModal", {
          title: "iOS 弹窗手势验证",
          content:
            "此弹窗用于验证在 iOS PlatformView 上弹出原生遮罩并关闭后，WebView 不会发生手势死锁或点击失效。\n\n点击“我知道了”关闭本弹窗后，再点击下方任意按钮测试点击响应！",
        })
          .then(function () {
            setOutput("DemoNativeModal: 原生弹窗已成功呼起并关闭，点击手势正常！");
          })
          .catch(function (error) {
            setOutput("DemoNativeModal 失败: " + error);
          })
          .finally(function () {
            setTimeout(function () {
              isModalBusy = false;
            }, 300);
          });
      });
    }

    var isPayBusy = false;
    // --- 模拟 1: Apple Pay (应用内半屏授权) ---
    if (payAppleBtn) {
      payAppleBtn.addEventListener("click", function () {
        if (isPayBusy) return;
        isPayBusy = true;
        setOutput("正在拉起 Apple Pay 原生半屏授权...");
        bridgeCall("DemoPayment", {
          payType: "apple_pay",
          orderId: "ORD-APPLE-888",
          amount: "99.00",
        })
          .then(function (result) {
            setOutput("Apple Pay 响应 (Direct Promise): " + JSON.stringify(result));
            if (result.status === "success") {
              updateOrderCardStatus("支付成功 (Apple Pay 交易号: " + result.transactionId + ")", true);
            } else if (result.status === "cancelled") {
              updateOrderCardStatus("用户取消支付 (Apple Pay)", false);
            } else {
              updateOrderCardStatus("支付失败: " + (result.memo || "系统异常") + " (Apple Pay)", false);
            }
          })
          .catch(function (error) {
            setOutput("Apple Pay 失败: " + error);
          })
          .finally(function () {
            setTimeout(function () {
              isPayBusy = false;
            }, 500);
          });
      });
    }

    // --- 模拟 2: 支付宝支付 (跳外部应用 + SDK 返回) ---
    if (payAlipayBtn) {
      payAlipayBtn.addEventListener("click", function () {
        if (isPayBusy) return;
        isPayBusy = true;
        setOutput("正在跳转至支付宝客户端...");
        bridgeCall("DemoPayment", {
          payType: "alipay",
          orderId: "ORD-ALI-666",
          amount: "99.00",
        })
          .then(function (result) {
            setOutput("支付宝 SDK 响应: " + JSON.stringify(result));
            if (result.status === "success") {
              updateOrderCardStatus("支付成功 (支付宝 交易号: " + result.tradeNo + ")", true);
            } else if (result.status === "cancelled") {
              updateOrderCardStatus("用户取消支付 (支付宝)", false);
            } else {
              updateOrderCardStatus("支付失败: " + (result.memo || "系统异常") + " (支付宝)", false);
            }
          })
          .catch(function (error) {
            setOutput("支付宝支付失败: " + error);
          })
          .finally(function () {
            setTimeout(function () {
              isPayBusy = false;
            }, 500);
          });
      });
    }

    // --- 模拟 3: 微信支付 (跳外部应用 + 异步全局 Delegate 事件派发) ---
    if (payWechatBtn) {
      payWechatBtn.addEventListener("click", function () {
        if (isPayBusy) return;
        isPayBusy = true;
        setOutput("正在拉起微信客户端 (异步委托回调模式)...");
        bridgeCall("DemoPayment", {
          payType: "wechat",
          orderId: "ORD-WX-999",
          amount: "99.00",
        })
          .then(function (result) {
            setOutput("微信拉起调用返回: " + JSON.stringify(result) + "\n等待原生 OpenSDK 异步事件回调 [PAY_RESULT]...");
          })
          .catch(function (error) {
            setOutput("微信支付拉起失败: " + error);
          })
          .finally(function () {
            setTimeout(function () {
              isPayBusy = false;
            }, 500);
          });
      });
    }

    if (enterSubBtn) {
      enterSubBtn.addEventListener("click", function () {
        goToSubView();
      });
    }

    if (backMainBtn) {
      backMainBtn.addEventListener("click", function () {
        goToMainView();
      });
    }

    if (subActionBtn) {
      subActionBtn.addEventListener("click", function () {
        setOutput("子页面操作触发成功！时间: " + new Date().toLocaleTimeString());
      });
    }

    // 全局事件监听器
    window.__AppEventBus.on(function (type, data) {
      if (type === "PAY_RESULT") {
        var payName =
          data.payType === "apple_pay"
            ? "Apple Pay"
            : data.payType === "alipay"
            ? "支付宝"
            : "微信支付";

        var isSuccess = data.status === "success";
        var statusDesc = "";
        if (isSuccess) {
          statusDesc =
            "支付成功 (" +
            payName +
            " 流水号: " +
            (data.transactionId || data.tradeNo || "OK") +
            ")";
        } else if (data.status === "cancelled") {
          statusDesc = "用户取消支付 (" + payName + ")";
        } else {
          statusDesc =
            "支付失败: " +
            (data.memo || "网络超时或系统异常") +
            " (" +
            payName +
            ")";
        }

        updateOrderCardStatus(statusDesc, isSuccess);
        setOutput(
          "收到原生支付回调事件通知 [PAY_RESULT]: " +
            JSON.stringify(data) +
            "\n页面无需刷新，订单状态已局部更新！"
        );
        return;
      }
      setOutput("收到原生事件推送: " + type + " " + JSON.stringify(data));
    });

    // 暴露统一规范的工具对象，与插件 web_payload_manager 命名对齐
    window.WebPayloadBridge = {
      call: bridgeCall,
      on: function (callback) {
        window.__AppEventBus.on(callback);
      },
      tryGoBack: window.__tryGoBack,
      version: "1.0.0",
    };
    window.$payload = window.WebPayloadBridge;

    setOutput("WebPayloadBridge 就绪。当前协议: Localhost HTTP | 离线资源包已挂载");
  }

  whenBridgeReady(bindDemoButtons);
})();
