from pathlib import Path
p = Path('.github/scripts/tests/test_windows_build.py')
text = p.read_bytes().decode('utf-8')
nl = '\r\n' if '\r\n' in text else '\n'
block = nl.join([
    "    def test_msix_identity_reads_environment_and_falls_back_when_empty(self):",
    "        def identity(environ):",
    "            try:",
    "                with patch.dict(build.os.environ, environ):",
    "                    spec.loader.exec_module(build)",
    "                    return build.MSIX_IDENTITY_NAME, build.MSIX_PUBLISHER",
    "            finally:",
    "                # 重新执行模块，把测试环境变量从模块全局里摘掉",
    "                spec.loader.exec_module(build)",
    "",
    "        self.assertEqual(",
    "            identity({",
    "                'MSIX_IDENTITY_NAME': 'ACGMN.VeneraUnified',",
    "                'MSIX_PUBLISHER': 'CN=60480894-F47F-462C-A648-F5E1B5D6EB8D',",
    "            }),",
    "            ('ACGMN.VeneraUnified', 'CN=60480894-F47F-462C-A648-F5E1B5D6EB8D'),",
    "        )",
    "        # 仓库变量没填时 CI 传进来的是空串而不是 None，必须回落到侧载默认身份。",
    "        self.assertEqual(",
    "            identity({'MSIX_IDENTITY_NAME': '', 'MSIX_PUBLISHER': ''}),",
    "            ('ACGNnsj.VeneraUnified', 'CN=ACGNnsj'),",
    "        )",
    "",
    "",
])
marker = nl + nl + "if __name__ == '__main__':"
assert text.count(marker) == 1, text[-200:]
text = text.replace(marker, nl + nl + block + "if __name__ == '__main__':")
p.write_bytes(text.encode('utf-8'))
print('patched')
