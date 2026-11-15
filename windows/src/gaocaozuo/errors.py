class AppError(Exception):
    def __init__(self, message: str, code: str = "invalid"):
        super().__init__(message)
        self.message = message
        self.code = code


class LayoutFailure(AppError):
    def __init__(self, message: str, rollback_verified: bool):
        suffix = (
            " 已确认恢复操作前的位置；原位置记录保留。"
            if rollback_verified
            else " 未能确认恢复操作前的位置；原位置记录已保留，请用“恢复原位置”重试。"
        )
        super().__init__(message + suffix, "layout")
        self.rollback_verified = rollback_verified
        self.reason = message
