#include "document.h"

#include <fstream>
#include <cmath>
#include <algorithm>
#include <pxr/base/tf/stringUtils.h>
#include <pxr/usd/sdf/copyUtils.h>
#include <pxr/usd/usdGeom/mesh.h>
#include <pxr/usd/usdGeom/metrics.h>
#include <pxr/usd/usdGeom/primvarsAPI.h>
#include <pxr/usd/usdGeom/xform.h>
#include <pxr/usd/usdShade/material.h>
#include <pxr/usd/usdShade/materialBindingAPI.h>
#include <pxr/usd/usdShade/shader.h>
#include <pxr/usd/usdUtils/dependencies.h>
#ifdef EDITOR_WITH_ASSIMP
#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <assimp/material.h>
#include <assimp/GltfMaterial.h>
#endif

PXR_NAMESPACE_USING_DIRECTIVE
namespace editor {
namespace {
UsdShadeMaterial make_material(const UsdStageRefPtr& stage, const SdfPath& path, const Json& properties) {
  auto material = UsdShadeMaterial::Define(stage, path);
  auto shader = UsdShadeShader::Define(stage, path.AppendChild(TfToken("Shader")));
  bool translucent = properties.value("kind", std::string("opaque")) == "translucent";
  const auto name = translucent ? "AperturePBR_Translucent" : "AperturePBR_Opacity";
  shader.CreateImplementationSourceAttr().Set(TfToken("sourceAsset"));
  shader.SetSourceAsset(SdfAssetPath(std::string("materials/") + name + ".mdl"), TfToken("mdl"));
  shader.SetSourceAssetSubIdentifier(TfToken(name), TfToken("mdl"));
  auto output = shader.CreateOutput(TfToken("out"), SdfValueTypeNames->Token);
  material.CreateSurfaceOutput(TfToken("mdl")).ConnectToSource(output);
  const auto color = properties.value("albedo", Json::array({0.7, 0.7, 0.7}));
  shader.CreateInput(TfToken("diffuse_color_constant"), SdfValueTypeNames->Color3f).Set(GfVec3f(color[0], color[1], color[2]));
  shader.CreateInput(TfToken("reflection_roughness_constant"), SdfValueTypeNames->Float).Set(properties.value("roughness", 0.5f));
  shader.CreateInput(TfToken("metallic_constant"), SdfValueTypeNames->Float).Set(properties.value("metallic", 0.f));
  shader.CreateInput(TfToken("opacity_constant"), SdfValueTypeNames->Float).Set(properties.value("opacity", 1.f));
  shader.CreateInput(TfToken("emissive_intensity"), SdfValueTypeNames->Float).Set(properties.value("emissive_intensity", 0.f));
  shader.CreateInput(TfToken("enable_emission"), SdfValueTypeNames->Bool).Set(properties.value("emissive_intensity", 0.f) > 0.f);
  const auto emission = properties.value("emissive", Json::array({1, 1, 1}));
  shader.CreateInput(TfToken("emissive_color_constant"), SdfValueTypeNames->Color3f).Set(GfVec3f(emission[0], emission[1], emission[2]));
  shader.CreateInput(TfToken("ior_constant"), SdfValueTypeNames->Float).Set(properties.value("ior", 1.5f));
  const auto transmission = properties.value("transmittance", color);
  shader.CreateInput(TfToken("transmittance_color"), SdfValueTypeNames->Color3f).Set(GfVec3f(transmission[0], transmission[1], transmission[2]));
  shader.CreateInput(TfToken("alpha_test_type"), SdfValueTypeNames->Int).Set(properties.value("alpha_test", 7));
  shader.CreateInput(TfToken("alpha_test_reference_value"), SdfValueTypeNames->Float).Set(properties.value("alpha_reference", 128.f));
  shader.CreateInput(TfToken("use_legacy_alpha_state"), SdfValueTypeNames->Bool).Set(false);
  shader.CreateInput(TfToken("blend_enabled"), SdfValueTypeNames->Bool).Set(properties.value("blend_enabled", false));
  shader.CreateInput(TfToken("blend_type"), SdfValueTypeNames->Int).Set(properties.value("blend_type", 0));
  shader.CreateInput(TfToken("inverted_blend"), SdfValueTypeNames->Bool).Set(properties.value("inverted_blend", false));
  for (const auto& [key, attr] : std::map<std::string, std::string>{{"albedo_texture", "diffuse_texture"},
      {"normal_texture", "normalmap_texture"}, {"roughness_texture", "reflectionroughness_texture"},
      {"metallic_texture", "metallic_texture"}, {"emissive_texture", "emissive_mask_texture"}}) {
    shader.CreateInput(TfToken(translucent && key == "albedo_texture" ? "transmittance_texture" : attr), SdfValueTypeNames->Asset).Set(SdfAssetPath(properties.value(key, std::string())));
  }
  return material;
}
void copy_materials(const Json& request, const fs::path& output) {
  auto directory = request.value("mdl_directory", std::string());
  if (directory.empty() || !fs::is_directory(directory)) throw std::runtime_error("Set the bundled AperturePBR material directory before ingesting assets");
  fs::copy(directory, output / "materials", fs::copy_options::recursive);
}
#ifdef EDITOR_WITH_ASSIMP
GfMatrix4d usd_matrix(const aiMatrix4x4& m) {
  return GfMatrix4d(m.a1, m.b1, m.c1, m.d1, m.a2, m.b2, m.c2, m.d2,
    m.a3, m.b3, m.c3, m.d3, m.a4, m.b4, m.c4, m.d4);
}
void import_node(const aiScene* scene, const aiNode* node, const UsdStageRefPtr& stage, const SdfPath& parent,
                 const std::vector<UsdShadeMaterial>& materials, unsigned& counter) {
  auto name = TfMakeValidIdentifier(node->mName.C_Str());
  auto path = parent.AppendChild(TfToken((name.empty() ? "node" : name) + "_" + std::to_string(counter++)));
  auto xform = UsdGeomXform::Define(stage, path);
  xform.MakeMatrixXform().Set(usd_matrix(node->mTransformation));
  for (unsigned i = 0; i < node->mNumMeshes; ++i) {
    const auto* source = scene->mMeshes[node->mMeshes[i]];
    if (source->HasBones()) throw std::runtime_error("Skinned meshes are outside the static ingestion workflow");
    auto mesh = UsdGeomMesh::Define(stage, path.AppendChild(TfToken("mesh_" + std::to_string(i))));
    VtVec3fArray points, normals;
    VtVec2fArray uv;
    for (unsigned v = 0; v < source->mNumVertices; ++v) {
      const auto p = source->mVertices[v]; points.push_back(GfVec3f(p.x, p.y, p.z));
      if (source->HasNormals()) { const auto n = source->mNormals[v]; normals.push_back(GfVec3f(n.x, n.y, n.z)); }
      if (source->HasTextureCoords(0)) { const auto t = source->mTextureCoords[0][v]; uv.push_back(GfVec2f(t.x, t.y)); }
    }
    VtIntArray counts, indices;
    for (unsigned f = 0; f < source->mNumFaces; ++f) {
      const auto& face = source->mFaces[f];
      if (face.mNumIndices != 3) continue;
      counts.push_back(3);
      for (unsigned j = 0; j < 3; ++j) indices.push_back(face.mIndices[j]);
    }
    mesh.CreatePointsAttr().Set(points); mesh.CreateNormalsAttr().Set(normals);
    mesh.SetNormalsInterpolation(UsdGeomTokens->vertex);
    mesh.CreateFaceVertexCountsAttr().Set(counts); mesh.CreateFaceVertexIndicesAttr().Set(indices);
    mesh.CreateSubdivisionSchemeAttr().Set(UsdGeomTokens->none);
    int double_sided = 0;
    if (source->mMaterialIndex < scene->mNumMaterials) scene->mMaterials[source->mMaterialIndex]->Get(AI_MATKEY_TWOSIDED, double_sided);
    mesh.CreateDoubleSidedAttr().Set(double_sided != 0);
    if (!uv.empty()) UsdGeomPrimvarsAPI(mesh).CreatePrimvar(TfToken("st"), SdfValueTypeNames->TexCoord2fArray, UsdGeomTokens->vertex).Set(uv);
    if (source->mMaterialIndex < materials.size()) UsdShadeMaterialBindingAPI::Apply(mesh.GetPrim()).Bind(materials[source->mMaterialIndex]);
  }
  for (unsigned i = 0; i < node->mNumChildren; ++i) import_node(scene, node->mChildren[i], stage, path, materials, counter);
}
#endif
}

Json ingest_asset(const Json& request, const fs::path& project_directory,
                  const TextureConverter& convert, const std::function<bool()>& canceled) {
  auto checkpoint = [&] { if (canceled && canceled()) throw std::runtime_error("Ingestion canceled"); };
  checkpoint();
  auto source = fs::absolute(request.at("source").get<std::string>());
  if (!fs::is_regular_file(source)) throw std::runtime_error("Asset does not exist: " + source.string());
  auto name = TfMakeValidIdentifier(request.value("name", source.stem().string()));
  if (name.empty()) throw std::runtime_error("Invalid asset name");
  auto destination = project_directory / "assets" / name;
  if (fs::exists(destination)) throw std::runtime_error("An asset with this name already exists; choose a different name");
  auto staging = project_directory / "assets" / ("." + name + ".ingesting");
  if (fs::exists(staging)) throw std::runtime_error("An ingestion job with this name already exists");
  fs::create_directories(staging);
  Json warnings = Json::array();
  try {
    auto extension = source.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
    const bool material_only = request.value("material", false);
    if (extension == ".usd" || extension == ".usda" || extension == ".usdc") {
      auto incoming = UsdStage::Open(source.string());
      if (!incoming || !incoming->GetDefaultPrim()) throw std::runtime_error("USD asset needs a default prim");
      // Flatten only the imported asset, never the user's project or capture layers.
      auto flattened = incoming->Flatten();
      size_t index = 0;
      std::map<std::string, std::string> copied;
      std::map<fs::path, fs::path> mdl_bundles;
      UsdUtilsModifyAssetPaths(flattened, [&](const std::string& asset) {
        if (asset.empty()) return asset;
        fs::path path(asset);
        if (!path.is_absolute()) path = source.parent_path() / path;
        if (!fs::is_regular_file(path)) throw std::runtime_error("Missing asset dependency: " + asset);
        auto key = fs::weakly_canonical(path).string();
        if (!copied.count(key)) {
          if (path.extension() == ".mdl") {
            auto parent = fs::weakly_canonical(path.parent_path());
            if (!mdl_bundles.count(parent)) {
              auto target = fs::path("materials_" + std::to_string(index++));
              mdl_bundles[parent] = target;
              for (const auto& entry : fs::recursive_directory_iterator(parent)) {
                if (!entry.is_regular_file()) continue;
                auto relative = fs::relative(entry.path(), parent);
                if (entry.path().extension() != ".mdl" && relative.begin()->string() != "PACKAGE-LICENSES") continue;
                auto output = staging / target / relative;
                fs::create_directories(output.parent_path()); fs::copy_file(entry.path(), output);
              }
            }
            copied[key] = (mdl_bundles.at(parent) / path.filename()).generic_string();
          } else {
            copied[key] = std::to_string(index++) + "_" + path.filename().string();
            fs::copy_file(path, staging / copied[key]);
          }
        }
        return copied.at(key);
      });
      if (!flattened->Export((staging / "asset.usda").string())) throw std::runtime_error("Could not export ingested asset");
    } else if (material_only) {
      copy_materials(request, staging);
      auto stage = UsdStage::CreateNew((staging / "asset.usda").string());
      Json properties = request.value("properties", Json::object());
      const auto role = request.value("texture_role", std::string("albedo"));
      const std::map<std::string, std::string> slots{{"albedo", "albedo_texture"}, {"normal", "normal_texture"},
        {"roughness", "roughness_texture"}, {"metallic", "metallic_texture"}, {"emissive", "emissive_texture"}};
      if (!slots.count(role)) throw std::runtime_error("Unknown material texture role");
      if (role == "emissive" && !properties.contains("emissive_intensity")) properties["emissive_intensity"] = 1.f;
      if (convert && extension != ".dds") {
        auto kind = role == "normal" ? request.value("normal_encoding", std::string("normal_ogl")) :
          (role == "roughness" || role == "metallic" ? "scalar" : "color");
        convert(source, staging / (role + ".dds"), kind);
        properties[slots.at(role)] = role + ".dds";
      } else {
        if (extension != ".dds") throw std::runtime_error("Texture conversion requires the Godot application; the CLI accepts existing DDS materials");
        fs::copy_file(source, staging / source.filename());
        properties[slots.at(role)] = source.filename().generic_string();
      }
      auto material = make_material(stage, SdfPath("/Material"), properties);
      stage->SetDefaultPrim(material.GetPrim());
      if (!stage->GetRootLayer()->Save()) throw std::runtime_error("Could not write material");
    } else {
#ifdef EDITOR_WITH_ASSIMP
      if (extension != ".fbx" && extension != ".obj" && extension != ".gltf" && extension != ".glb")
        throw std::runtime_error("Supported models: USD, glTF, GLB, FBX, OBJ");
      Assimp::Importer importer;
      auto imported = importer.ReadFile(source.string(), aiProcess_Triangulate | aiProcess_GenSmoothNormals | aiProcess_ValidateDataStructure);
      if (!imported || !imported->mRootNode) throw std::runtime_error(importer.GetErrorString());
      copy_materials(request, staging);
      auto stage = UsdStage::CreateNew((staging / "asset.usda").string());
      auto root = UsdGeomXform::Define(stage, SdfPath("/ReferenceTarget"));
      stage->SetDefaultPrim(root.GetPrim());
      UsdGeomSetStageUpAxis(stage, UsdGeomTokens->y);
      UsdGeomSetStageMetersPerUnit(stage, 1.0);
      // Assimp applies FBX axis and UnitScaleFactor metadata into a centimeter root transform.
      double scale = request.value("scale", 1.0) * (extension == ".fbx" ? 0.01 : 1.0);
      if (!std::isfinite(scale) || scale <= 0) throw std::runtime_error("Import scale must be positive");
      GfMatrix4d matrix; matrix.SetScale(scale); root.MakeMatrixXform().Set(matrix);
      std::vector<UsdShadeMaterial> materials;
      for (unsigned i = 0; i < imported->mNumMaterials; ++i) {
        checkpoint();
        Json properties;
        const auto* mat = imported->mMaterials[i];
        aiColor4D color(0.7, 0.7, 0.7, 1);
        aiGetMaterialColor(mat, AI_MATKEY_COLOR_DIFFUSE, &color);
        aiGetMaterialColor(mat, AI_MATKEY_BASE_COLOR, &color);
        properties["albedo"] = {color.r, color.g, color.b};
        properties["opacity"] = color.a;
        aiString alpha_mode;
        mat->Get(AI_MATKEY_GLTF_ALPHAMODE, alpha_mode);
        if (std::string(alpha_mode.C_Str()) == "MASK") {
          float cutoff = 0.5f; mat->Get(AI_MATKEY_GLTF_ALPHACUTOFF, cutoff);
          properties["alpha_test"] = 6;
          properties["alpha_reference"] = int(std::clamp(cutoff, 0.f, 1.f) * 255.f);
        }
        float transmission = 0.f, ior = 1.5f;
        mat->Get(AI_MATKEY_TRANSMISSION_FACTOR, transmission); mat->Get(AI_MATKEY_REFRACTI, ior);
        if (transmission > 0) { properties["kind"] = "translucent"; properties["ior"] = ior; }
        else if (std::string(alpha_mode.C_Str()) == "BLEND") properties["blend_enabled"] = true;
        aiColor3D emission(0, 0, 0); mat->Get(AI_MATKEY_COLOR_EMISSIVE, emission);
        const auto emission_intensity = std::max({emission.r, emission.g, emission.b});
        properties["emissive_intensity"] = emission_intensity;
        if (emission_intensity > 0) properties["emissive"] = {emission.r / emission_intensity, emission.g / emission_intensity, emission.b / emission_intensity};
        float roughness = 0.5f, metallic = 0.f;
        mat->Get(AI_MATKEY_ROUGHNESS_FACTOR, roughness); mat->Get(AI_MATKEY_METALLIC_FACTOR, metallic);
        properties["roughness"] = roughness; properties["metallic"] = metallic;
        for (auto [type, key] : std::vector<std::pair<aiTextureType, std::string>>{
            {aiTextureType_BASE_COLOR, "albedo_texture"}, {aiTextureType_DIFFUSE, "albedo_texture"},
            {aiTextureType_NORMALS, "normal_texture"}, {aiTextureType_EMISSIVE, "emissive_texture"},
            {aiTextureType_DIFFUSE_ROUGHNESS, "roughness_texture"}, {aiTextureType_METALNESS, "metallic_texture"}}) {
          aiString name;
          if (properties.contains(key)) continue;
          if (mat->GetTexture(type, 0, &name) != AI_SUCCESS) continue;
          auto embedded = imported->GetEmbeddedTexture(name.C_Str());
          auto file_name = "texture_" + std::to_string(i) + "_" + key;
          if (embedded) {
            if (embedded->mHeight != 0) throw std::runtime_error("Uncompressed embedded textures require conversion before import");
            file_name += "." + std::string(embedded->achFormatHint);
            std::ofstream stream(staging / file_name, std::ios::binary);
            stream.write(reinterpret_cast<const char*>(embedded->pcData), embedded->mWidth);
            if (!stream) throw std::runtime_error("Could not write embedded texture");
          } else {
            // FBX stores paths from the exporting OS. On Linux, filesystem::path
            // treats Windows separators as literal filename characters.
            auto texture_name = std::string(name.C_Str());
            std::replace(texture_name.begin(), texture_name.end(), '\\', '/');
            auto texture_path = (source.parent_path() / fs::path(texture_name)).lexically_normal();
            if (!fs::is_regular_file(texture_path)) throw std::runtime_error("Missing model texture: " + texture_path.string());
            file_name += texture_path.extension().string();
            fs::copy_file(texture_path, staging / file_name);
          }
          properties[key] = file_name;
          if (fs::path(file_name).extension() != ".dds") {
            if (!convert) throw std::runtime_error("Textured model conversion requires the Godot application");
            auto converted = fs::path(file_name).stem().string() + ".dds";
            std::string kind = "color";
            if (key == "normal_texture") kind = request.value("normal_encoding", std::string("normal_ogl"));
            if (key == "roughness_texture" || key == "metallic_texture")
              kind = (extension == ".gltf" || extension == ".glb") ? (key == "roughness_texture" ? "roughness_g" : "metallic_b") : "scalar";
            convert(staging / file_name, staging / converted, kind);
            fs::remove(staging / file_name);
            properties[key] = converted;
          }
        }
        materials.push_back(make_material(stage, SdfPath("/ReferenceTarget/Looks/Material_" + std::to_string(i)), properties));
      }
      unsigned counter = 0;
      import_node(imported, imported->mRootNode, stage, root.GetPath(), materials, counter);
      if (!stage->GetRootLayer()->Save()) throw std::runtime_error("Could not write imported model");
#else
      throw std::runtime_error("This build has no Assimp; configure with the Assimp SDK to import FBX, OBJ, or glTF");
#endif
    }
    std::ofstream metadata(staging / "ingestion.json");
    metadata << Json{{"schema", 1}, {"source", source.generic_string()}, {"warnings", warnings}}.dump(2);
    metadata.close();
    checkpoint();
    fs::rename(staging, destination);
  } catch (...) { fs::remove_all(staging); throw; }
  return {{"asset", (destination / "asset.usda").generic_string()}, {"warnings", warnings}};
}
}
