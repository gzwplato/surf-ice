//vert
#version 330
layout(location = 0) in vec3 Vert;
layout(location = 3) in vec3 Norm;
layout(location = 6) in vec4 Clr;
uniform mat4 ModelViewProjectionMatrix;
uniform mat3 NormalMatrix;
out vec4 vClr;
out vec4 vP;
out vec3 vN;
void main() {
    gl_Position = ModelViewProjectionMatrix * vec4(Vert, 1.0);
    vP = gl_Position;
    vClr = Clr;
    vN = normalize((NormalMatrix * Norm));
}
//geom
#version 330
layout (triangle_strip, max_vertices = 5) out;
layout (lines_adjacency) in;
in vec4 vP[4]; // Four inputs since we're using GL_LINE_STRIP_ADJACENCY
in vec4 vClr[4];
in vec3 vN[4];

uniform float Radius = 1.0;
float THICKNESS = Radius;		// the thickness of the line in pixels
//uniform vec2 ScreenPixels = vec2(800,800);		// the size of the viewport in pixels
uniform vec2 ScreenPixels = vec2(1600,1600);		// the size of the viewport in pixels

out vec2 gsTexCoord;
out vec4 gClr;
out vec3 gN;

vec2 screen_space(vec4 vertex)
{
	return vec2( vertex.xy / vertex.w ) * ScreenPixels;
}

void main(void)
{
  // get the four vertices passed to the shader:
  vec2 p0 = screen_space( vP[0] );	// start of previous segment
  vec2 p1 = screen_space( vP[1] );	// end of previous segment, start of current segment
  vec2 p2 = screen_space( vP[2] );	// end of current segment, start of next segment
  vec2 p3 = screen_space( vP[3] );	// end of next segment

  // perform naive culling
  //vec2 area = ScreenPixels * 1.2;
  //if( p1.x < -area.x || p1.x > area.x ) return;
  //if( p1.y < -area.y || p1.y > area.y ) return;
  //if( p2.x < -area.x || p2.x > area.x ) return;
  //if( p2.y < -area.y || p2.y > area.y ) return;

  // determine the direction of each of the 3 segments (previous, current, next)
  vec2 v0 = normalize(p1-p0);
  vec2 v1 = normalize(p2-p1);
  vec2 v2 = normalize(p3-p2);

  // determine the normal of each of the 3 segments (previous, current, next)
  vec2 n0 = vec2(-v0.y, v0.x);
  vec2 n1 = vec2(-v1.y, v1.x);
  vec2 n2 = vec2(-v2.y, v2.x);

  // determine miter lines by averaging the normals of the 2 segments
  vec2 miter_a = normalize(n0 + n1);	// miter at start of current segment
  vec2 miter_b = normalize(n1 + n2);	// miter at end of current segment
  float kEps = 0.1;
  //if ( ( abs(dot(miter_a, n1)) < kEps) || (abs(dot(miter_b, n1)) < kEps)) return;
  // determine the length of the miter by projecting it onto normal and then inverse it
  float length_a = 0.0;
  float length_b = 0.0;
  if ( abs(dot(miter_a, n1)) > kEps)
  	length_a = THICKNESS / dot(miter_a, n1);
  if ( abs(dot(miter_b, n1)) > kEps)
  	length_b = THICKNESS / dot(miter_b, n1);
  //if (length_a <= 0.0) return;
  //if (length_b <= 0.0) return;
  //if (length_a > 20.0) return;
  //if (length_b > 20.0) return;
  //if ( dot(v0,n1) == 0 ) return;
  //if ( dot(v2,n1) == 0 ) return;

  gN = normalize(vN[1] + vN[2]);
  //gN = vN[2];
  gClr = vClr[1];
  if( dot(v0,n1) > 0 ) {
    // start at negative miter
    gsTexCoord = vec2(0, 1);
	gl_Position = vec4( (p1 - length_a * miter_a) / ScreenPixels, vP[1].z, 1.0 );
	EmitVertex();
	// proceed to positive normal
    gsTexCoord = vec2(0, 0);
    gl_Position = vec4( (p1 + THICKNESS * n1) / ScreenPixels, vP[1].z, 1.0 );
	EmitVertex();
 }
 else {
    // start at negative normal
    gsTexCoord = vec2(0, 1);
    gl_Position = vec4( (p1 - THICKNESS * n1) / ScreenPixels, vP[1].z, 1.0 );
	EmitVertex();
	// proceed to positive miter
    gsTexCoord = vec2(0, 0);
    gl_Position = vec4( (p1 + length_a * miter_a) / ScreenPixels, vP[1].z, 1.0 );
	EmitVertex();
  }
  gClr = vClr[2];
  //gN = vN[2];
  if( dot(v2,n1) < 0 ) {
	// proceed to negative miter
    gsTexCoord = vec2(0, 1);
    gl_Position = vec4( (p2 - length_b * miter_b) / ScreenPixels, vP[2].z, 1.0 );
	EmitVertex();
	// proceed to positive normal
    gsTexCoord = vec2(0, 0);
    gl_Position = vec4( (p2 + THICKNESS * n1) / ScreenPixels, vP[2].z, 1.0 );
	EmitVertex();
	// end at positive normal
    gsTexCoord = vec2(0, 0);
    gl_Position = vec4( (p2 + THICKNESS * n2) / ScreenPixels, vP[2].z, 1.0 );
	EmitVertex();
  }
  else {
    // proceed to negative normal
    gsTexCoord = vec2(0, 1);
    gl_Position = vec4( (p2 - THICKNESS * n1) / ScreenPixels, vP[2].z, 1.0 );
	EmitVertex();
	// proceed to positive miter
    gsTexCoord = vec2(0, 0);
    gl_Position = vec4( (p2 + length_b * miter_b) / ScreenPixels, vP[2].z, 1.0 );
	EmitVertex();
	// end at negative normal
    gsTexCoord = vec2(0, 1);
    gl_Position = vec4( (p2 - THICKNESS * n2) / ScreenPixels, vP[2].z, 1.0 );
	EmitVertex();
  }
  EndPrimitive();
}

//frag
#version 330
in vec4 gClr;
in vec3 gN;
out vec4 color;
void main()
{
	vec3 specClr = vec3(0.7, 0.7, 0.7);
	vec3 difClr = gClr.rgb * 0.9;
	vec3 ambClr = gClr.rgb * 0.1;
	//difClr = vec3(0.4, 0.0, 0.4);
	//ambClr = vec3(0.0, 0.4, 0.4);
	vec3 L = vec3(0.707, 0.707, 0.0);
    vec3 n = abs(normalize(gN));
   	float spec = pow(dot(n,L),100.0);
    float dif = dot(L,n);

    //spec = 0.0;
    //dif = 0.8;
    color = vec4(specClr*spec + difClr*dif + ambClr,1.0);
    //color = vec4(gClr.rgb, 1.0);
}