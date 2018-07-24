package h3d.scene.pbr;

@:enum abstract DisplayMode(String) {
	/*
		Full PBR display
	*/
	var Pbr = "Pbr";
	/*
		Set Albedo = 0x808080
	*/
	var Env = "Env";
	/*
		Set Albedo = 0x808080, Roughness = 0, Metalness = 1
	*/
	var MatCap = "MatCap";
	/*
		Debug slides
	*/
	var Debug = "Debug";
}

@:enum abstract SkyMode(String) {
	var Hide = "Hide";
	var Env = "Env";
	var Irrad = "Irrad";
}

@:enum abstract TonemapMap(String) {
	var Linear = "Linear";
	var Reinhard = "Reinhard";
}

typedef RenderProps = {
	var mode : DisplayMode;
	var env : String;
	var envPower : Float;
	var exposure : Float;
	var sky : SkyMode;
	var tone : TonemapMap;
	var emissive : Float;
	var occlusion : Float;
}

class Renderer extends h3d.scene.Renderer {
	var slides = new h3d.pass.ScreenFx(new h3d.shader.pbr.Slides());
	var pbrOut = new h3d.pass.ScreenFx(new h3d.shader.ScreenShader());
	var pbrOutIndirect = new h3d.pass.ScreenFx(new h3d.shader.ScreenShader());
	var tonemap = new h3d.pass.ScreenFx(new h3d.shader.pbr.ToneMapping());
	var pbrSun = new h3d.shader.pbr.Light.DirLight();
	var pbrLightPass : h3d.mat.Pass;
	var screenLightPass : h3d.pass.ScreenFx<h3d.shader.ScreenShader>;
	var fxaa = new h3d.pass.FXAA();
	var pbrIndirect = new h3d.shader.pbr.Lighting.Indirect();
	var pbrDirect = new h3d.shader.pbr.Lighting.Direct();
	var pbrProps = new h3d.shader.pbr.PropsImport();
	var hasDebugEvent = false;
	var curDirShadow : hxsl.Shader;

	public var skyMode : SkyMode = Hide;
	public var toneMode : TonemapMap = Reinhard;
	public var displayMode : DisplayMode = Pbr;
	public var env : Environment;
	public var exposure(get,set) : Float;
	public var debugMode = 0;

	static var ALPHA : hxsl.Output = Swiz(Value("output.color"),[W]);
	var output = new h3d.pass.Output("mrt",[
		Value("output.color"),
		Vec4([Value("output.normal",3),ALPHA]),
		Vec4([Value("output.metalness"), Value("output.roughness"), Value("output.occlusion"), ALPHA]),
		Vec4([Value("output.emissive"),Value("output.depth"),Const(0), ALPHA /* ? */])
	]);
	var decalsOutput = new h3d.pass.Output("decals",[
		Vec4([Swiz(Value("output.color"),[X,Y,Z]), Value("output.albedoStrength",1)]),
		Vec4([Value("output.normal",3), Value("output.normalStrength",1)]),
		Vec4([Value("output.metalness"), Value("output.roughness"), Value("output.occlusion"), Value("output.pbrStrength")]),
	]);

	public function new(env) {
		super();
		this.env = env;
		defaultPass = new h3d.pass.Default("default");
		pbrOut.addShader(pbrProps);
		slides.addShader(pbrProps);
		pbrOutIndirect.addShader(pbrIndirect);
		pbrOutIndirect.addShader(pbrProps);
		pbrOutIndirect.pass.setBlendMode(Add);
		pbrOutIndirect.pass.stencil = new h3d.mat.Stencil();
		pbrOutIndirect.pass.stencil.setOp(Keep, Keep, Keep);
		allPasses.push(output);
		allPasses.push(defaultPass);
		allPasses.push(decalsOutput);
		refreshProps();
	}

	inline function get_exposure() return tonemap.shader.exposure;
	inline function set_exposure(v:Float) return tonemap.shader.exposure = v;

	override function debugCompileShader(pass:h3d.mat.Pass) {
		output.setContext(this.ctx);
		return output.compileShader(pass);
	}

	override function start() {
		if( pbrLightPass == null ) {
			pbrLightPass = new h3d.mat.Pass("lights");
			pbrLightPass.addShader(new h3d.shader.BaseMesh());
			pbrLightPass.addShader(pbrDirect);
			pbrLightPass.addShader(pbrProps);
			pbrLightPass.blend(One, One);
			/*
				This allows to discard light pixels when there is nothing
				between light volume and camera. Also prevents light shape
				to be discarded when the camera is inside its volume.
			*/
			pbrLightPass.culling = Front;
			pbrLightPass.depth(false, Greater);
			pbrLightPass.enableLights = true;
		}
		ctx.pbrLightPass = pbrLightPass;
	}

	function mainDraw() {
		output.draw(getSort("default", true));
		output.draw(getSort("alpha"));
		output.draw(get("additive"));
	}

	function postDraw() {
		draw("overlay");
	}

	function apply( step : hxd.prefab.rfx.RendererFX.Step ) {
		for( f in effects )
			if( f.enabled )
				f.apply(this, step);
	}

	override function computeStatic() {
		var light = @:privateAccess ctx.lights;
		var passes = get("shadow");
		while( light != null ) {
			var plight = Std.instance(light, h3d.scene.pbr.Light);
			if( plight != null ) {
				plight.shadows.setContext(ctx);
				plight.shadows.computeStatic(passes);
			}
			light = light.next;
		}
	}

	override function render() {
		var props : RenderProps = props;
		var ls = getLightSystem();

		var light = @:privateAccess ctx.lights;
		var passes = get("shadow");
		while( light != null ) {
			var plight = Std.instance(light, h3d.scene.pbr.Light);
			if( plight != null ) {
				plight.shadows.setContext(ctx);
				plight.shadows.draw(passes);
			}
			light = light.next;
		}

		var albedo = allocTarget("albedo");
		var normal = allocTarget("normalDepth",false,1.,RGBA16F);
		var pbr = allocTarget("pbr",false,1.);
		var other = allocTarget("other",false,1.,RGBA32F);

		ctx.setGlobal("albedoMap",{ texture : albedo, channel : hxsl.Channel.R });
		ctx.setGlobal("depthMap",{ texture : other, channel : hxsl.Channel.G });
		ctx.setGlobal("normalMap",{ texture : normal, channel : hxsl.Channel.R });
		ctx.setGlobal("occlusionMap",{ texture : pbr, channel : hxsl.Channel.B });
		ctx.setGlobal("bloom",null);

		setTargets([albedo,normal,pbr,other]);
		clear(0, 1, 0);
		mainDraw();

		setTargets([albedo,normal,pbr]);
		decalsOutput.draw(get("decal"));

		setTarget(albedo);
		draw("albedo");

		if(renderMode == Default){
			if( displayMode == Env )
				clear(0xFF404040);

			if( displayMode == MatCap ) {
				clear(0xFF808080);
				setTarget(pbr);
				clear(0x00FF80FF);
			}
		}
		apply(BeforeHdr);


		var hdr = allocTarget("hdrOutput", true, 1, RGBA16F);
		ctx.setGlobal("hdr", hdr);
		setTarget(hdr);
		if( renderMode == LightProbe )
			clear(0);
		else if( ctx.engine.backgroundColor != null )
			clear(ctx.engine.backgroundColor);

		pbrProps.albedoTex = albedo;
		pbrProps.normalTex = normal;
		pbrProps.pbrTex = pbr;
		pbrProps.otherTex = other;
		pbrProps.cameraInverseViewProj = ctx.camera.getInverseViewProj();
		pbrProps.occlusionPower = props.occlusion * props.occlusion;

		pbrDirect.cameraPosition.load(ctx.camera.pos);
		pbrIndirect.cameraPosition.load(ctx.camera.pos);
		pbrIndirect.emissivePower = props.emissive * props.emissive;
		pbrIndirect.irrPower = env.power * env.power;
		pbrIndirect.irrLut = env.lut;
		pbrIndirect.irrDiffuse = env.diffuse;
		pbrIndirect.irrSpecular = env.specular;
		pbrIndirect.irrSpecularLevels = env.specLevels;

		if( ls.shadowLight == null ) {
			if( curDirShadow != null ) {
				pbrOut.removeShader(curDirShadow);
				curDirShadow = null;
			}
			pbrOut.removeShader(pbrDirect);
			pbrOut.removeShader(pbrSun);
		} else {
			var pdir = Std.instance(ls.shadowLight, h3d.scene.pbr.DirLight);
			var pshadow = @:privateAccess pdir == null ? null : pdir.shadows.shader;
			if( pshadow != curDirShadow ) {
				if( curDirShadow != null ) pbrOut.removeShader(curDirShadow);
				curDirShadow = pshadow;
				if( pshadow != null ) pbrOut.addShader(pshadow);
			}
			if( pbrOut.getShader(h3d.shader.pbr.Light.DirLight) == null ) {
				pbrOut.addShader(pbrDirect);
				pbrOut.addShader(pbrSun);
			}
			// works with both pre-pbr DirLight and pbr DirLight
			pbrSun.lightColor.load(ls.shadowLight.color);
			if( pdir != null ) pbrSun.lightColor.scale3(pdir.power * pdir.power);
			pbrSun.lightDir.load(@:privateAccess ls.shadowLight.getShadowDirection());
			pbrSun.lightDir.scale3(-1);
			pbrSun.lightDir.normalize();
		}

		pbrOut.setGlobals(ctx);
		pbrDirect.doDiscard = false;
		pbrIndirect.cameraInvViewProj.load(ctx.camera.getInverseViewProj());
		switch( renderMode ) {
		case Default:
			pbrIndirect.drawIndirectDiffuse = true;
			pbrIndirect.drawIndirectSpecular= true;
			pbrIndirect.showSky = skyMode != Hide;
			pbrIndirect.skyMap = skyMode == Irrad ? env.diffuse : env.env;
		case LightProbe:
			pbrIndirect.drawIndirectDiffuse = false;
			pbrIndirect.drawIndirectSpecular= false;
			pbrIndirect.showSky = true;
			pbrIndirect.skyMap = env.env;
		}

		if( ls.shadowLight != null )
			pbrOut.render();
		pbrDirect.doDiscard = true;

		var ls = Std.instance(ls, LightSystem);
		var lpass = screenLightPass;
		if( lpass == null ) {
			lpass = new h3d.pass.ScreenFx(new h3d.shader.ScreenShader());
			lpass.addShader(pbrProps);
			lpass.addShader(pbrDirect);
			lpass.pass.setBlendMode(Add);
			screenLightPass = lpass;
		}
		if( ls != null ) ls.drawLights(this, lpass);

		pbrProps.isScreen = false;
		draw("lights");

		if( renderMode == LightProbe ) {
			pbrProps.isScreen = true;
			pbrOutIndirect.render();
			resetTarget();
			copy(hdr, null);
			// no warnings
			for( p in passObjects ) if( p != null ) p.rendered = true;
			return;
		}

		ctx.extraShaders = new hxsl.ShaderList(pbrProps, null);
		draw("volumetricLightmap");
		ctx.extraShaders = null;

		pbrProps.isScreen = true;

		pbrIndirect.drawIndirectDiffuse = true;
		pbrIndirect.drawIndirectSpecular = false;
		pbrOutIndirect.pass.stencil.setFunc(NotEqual, 0x80, 0x80, 0x80);
		pbrOutIndirect.render();

		pbrIndirect.drawIndirectDiffuse = false;
		pbrIndirect.drawIndirectSpecular = true;
		pbrOutIndirect.pass.stencil.setFunc(Always);
		pbrOutIndirect.render();

		apply(AfterHdr);

		var ldr = allocTarget("ldrOutput");
		setTarget(ldr);
		var bloom = ctx.getGlobal("bloom");
		tonemap.shader.bloom = bloom;
		tonemap.shader.hasBloom = bloom != null;
		tonemap.shader.mode = switch( toneMode ) {
		case Linear: 0;
		case Reinhard: 1;
		default: 0;
		};
		tonemap.shader.hdrTexture = hdr;
		tonemap.render();

		postDraw();
		resetTarget();


		switch( displayMode ) {

		case Pbr, Env, MatCap:
			fxaa.apply(ldr);

		case Debug:

			var shadowMap = ctx.textures.getNamed("shadowMap");
			slides.shader.shadowMap = shadowMap;
			slides.render();

			if( !hasDebugEvent ) {
				hasDebugEvent = true;
				hxd.Stage.getInstance().addEventTarget(onEvent);
			}

		}

		if( hasDebugEvent && displayMode != Debug ) {
			hasDebugEvent = false;
			hxd.Stage.getInstance().removeEventTarget(onEvent);
		}
	}

	function onEvent(e:hxd.Event) {
		if( e.kind == EPush && e.button == 2 ) {
			var st = hxd.Stage.getInstance();
			var x = Std.int((e.relX / st.width) * 4);
			var y = Std.int((e.relY / st.height) * 4);
			if( slides.shader.mode != Full ) {
				slides.shader.mode = Full;
			} else {
				var a : Array<h3d.shader.pbr.Slides.DebugMode>;
				if( y == 3 )
					a = [Emmissive,Depth,AO,Shadow];
				else
					a = [Albedo,Normal,Roughness,Metalness];
				slides.shader.mode = a[x];
			}
		}
	}

	// ---- PROPS

	override function getDefaultProps( ?kind : String ):Any {
		var props : RenderProps = {
			mode : Pbr,
			env : null,
			envPower : 1.,
			emissive : 1.,
			exposure : 0.,
			sky : Irrad,
			tone : Linear,
			occlusion : 1.
		};
		return props;
	}

	override function refreshProps() {
		if( env == null )
			return;
		var props : RenderProps = props;
		if( props.env != null && props.env != env.source.name ) {
			var t = hxd.res.Loader.currentInstance.load(props.env).toTexture();
			var prev = env;
			var env = new h3d.scene.pbr.Environment(t);
			env.compute();
			this.env = env;
			prev.dispose();
		}
		displayMode = props.mode;
		skyMode = props.sky;
		toneMode = props.tone;
		exposure = props.exposure;
		env.power = props.envPower;
	}

	#if js
	override function editProps() {
		var props : RenderProps = props;
		return new js.jquery.JQuery('
			<div class="group" name="Renderer">
			<dl>
				<dt>Tone</dt>
				<dd>
					<select field="tone">
						<option value="Linear">Linear</option>
						<option value="Reinhard">Reinhard</option>
					</select>
				</dd>
				<dt>Mode</dt>
				<dd>
					<select field="mode">
						<option value="Pbr">PBR</option>
						<option value="Env">Env</option>
						<option value="MatCap">MatCap</option>
						<option value="Debug">Debug</option>
					</select>
				</dd>
				<dt>Env</dt>
				<dd>
					<input type="texturepath" field="env" style="width:165px"/>
					<select field="sky" style="width:20px">
						<option value="Hide">Hide</option>
						<option value="Env">Show</option>
						<option value="Irrad">Show Irrad</option>
					</select>
					<br/>
					<input type="range" min="0" max="2" field="envPower"/>
				</dd>
				<dt>Emissive</dt><dd><input type="range" min="0" max="2" field="emissive"></dd>
				<dt>Occlusion</dt><dd><input type="range" min="0" max="2" field="occlusion"></dd>
				<dt>Exposure</dt><dd><input type="range" min="-3" max="3" field="exposure"></dd>
			</dl>
			</div>
		');
	}
	#end
}