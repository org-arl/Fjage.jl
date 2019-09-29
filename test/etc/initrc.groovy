import org.arl.fjage.*
import org.arl.fjage.remote.*
import org.arl.fjage.shell.*
import org.arl.fjage.connectors.*

platform = new RealTimePlatform()
container = new MasterContainer(platform, 5081)
shell = new ShellAgent(new GroovyScriptEngine())
container.add 'shell', shell
platform.start()
