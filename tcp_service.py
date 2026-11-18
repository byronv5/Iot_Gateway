"""巡检开关 Windows 服务入口。打包后的 DoorCtrl.exe 不依赖目标电脑上的 Python。"""
from __future__ import annotations

import sys

import servicemanager
import win32service
import win32serviceutil

import tcp_server


class DoorCtrlService(win32serviceutil.ServiceFramework):
    _svc_name_ = "DoorCtrl"
    _svc_display_name_ = "巡检开关服务"
    _svc_description_ = "局域网 TCP 开关服务"

    def __init__(self, args: list[str]) -> None:
        win32serviceutil.ServiceFramework.__init__(self, args)
        self._server: tcp_server.SwitchServer | None = None

    def SvcStop(self) -> None:
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
        server = self._server
        if server is not None:
            server.shutdown()

    def SvcDoRun(self) -> None:
        servicemanager.LogInfoMsg("巡检开关服务启动")
        self._server = tcp_server.open_server()
        try:
            self._server.serve_forever()
        finally:
            self._server.server_close()


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "run":
        tcp_server.main()
        return
    if len(sys.argv) > 1:
        win32serviceutil.HandleCommandLine(DoorCtrlService)
        return
    servicemanager.Initialize()
    servicemanager.PrepareToHostSingle(DoorCtrlService)
    servicemanager.StartServiceCtrlDispatcher()


if __name__ == "__main__":
    main()
